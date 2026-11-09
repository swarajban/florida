import { randomUUID } from 'node:crypto'
import { DAY, schedule } from '@florida/scheduler'
import type { Interval, Schedule, SchedulerInput, SchedulerResult, Task } from '@florida/scheduler'
import { and, eq, getTableColumns, isNull, sql } from 'drizzle-orm'
import type { Config } from './config.js'
import type { Db } from './db/client.js'
import { calendars, events, placements, categories, schedules, tasks, unscheduled } from './db/schema.js'
import type { EventRow, CategoryRow, PlacementRow, ScheduleRow, TaskRow } from './db/schema.js'
import { materializeRecurringTasks } from './tasks.js'

export interface SchedulerSources {
  now: Date
  horizonDays: number
  schedules: ScheduleRow[]
  categories: CategoryRow[]
  tasks: TaskRow[]
  events: EventRow[]
  /** The last run's output; the scheduler keeps these blocks where it still can. Omit for a fresh plan. */
  previous?: PlacementRow[]
}

/**
 * Maps database rows to scheduler input. Pure.
 *
 * A task uses its own `scheduleId` when set, otherwise its category's. Tasks that are deleted,
 * completed, or belong to a deleted category are skipped. Busy time is every live, timed, opaque,
 * not-declined event that overlaps [now, now + horizon). Previous placements go through as-is;
 * the scheduler itself decides which are still valid.
 */
export function buildSchedulerInput(src: SchedulerSources): SchedulerInput {
  const nowMs = src.now.getTime()
  const horizonEnd = nowMs + src.horizonDays * DAY

  const liveSchedules: Schedule[] = src.schedules
    .filter((s) => s.deletedAt === null)
    .map((s) => ({ id: s.id, timeZone: s.timeZone, windows: s.windows }))

  const categorySchedule = new Map(
    src.categories.filter((p) => p.deletedAt === null).map((p) => [p.id, p.scheduleId] as const),
  )

  const openTasks: Task[] = []
  for (const t of src.tasks) {
    if (t.deletedAt !== null || t.completedAt !== null) continue
    const categoryScheduleId = categorySchedule.get(t.categoryId)
    if (categoryScheduleId === undefined) continue
    const task: Task = {
      id: t.id,
      scheduleId: t.scheduleId ?? categoryScheduleId,
      durationMinutes: t.durationMinutes,
      priority: t.priority,
      deadlineType: t.deadlineType,
      completedMinutes: t.completedMinutes,
      createdAt: t.createdAt.toISOString(),
    }
    if (t.minChunkMinutes !== null) task.minChunkMinutes = t.minChunkMinutes
    if (t.dueAt !== null) task.dueAt = t.dueAt.toISOString()
    if (t.startAt !== null) task.startAt = t.startAt.toISOString()
    if (t.pinnedStart !== null) task.pinnedStart = t.pinnedStart.toISOString()
    openTasks.push(task)
  }

  const busy: Interval[] = []
  for (const e of src.events) {
    if (e.deletedAt !== null || e.status === 'cancelled' || e.allDay) continue
    if (e.transparency === 'transparent' || e.responseStatus === 'declined') continue
    if (e.startAt === null || e.endAt === null) continue
    const start = e.startAt.getTime()
    const end = e.endAt.getTime()
    if (end <= start || end <= nowMs || start >= horizonEnd) continue
    busy.push({ start: e.startAt.toISOString(), end: e.endAt.toISOString() })
  }

  const input: SchedulerInput = {
    now: src.now.toISOString(),
    schedules: liveSchedules,
    tasks: openTasks,
    busy,
    horizonDays: src.horizonDays,
  }
  if (src.previous !== undefined) {
    input.previous = src.previous.map((p) => ({
      taskId: p.taskId,
      start: p.startAt.toISOString(),
      end: p.endAt.toISOString(),
      pinned: p.pinned,
    }))
  }
  return input
}

/** Arbitrary constant; serializes scheduler runs across processes via a transaction-scoped advisory lock. */
const SCHEDULER_LOCK_SQL = 'select pg_advisory_xact_lock(731104)'

/**
 * Loads the current state, runs the scheduler, and replaces the `placements` and `unscheduled`
 * tables with the result inside one transaction. Returns the scheduler result so callers can relay it.
 *
 * The outgoing `placements` rows are fed back as `previous`, so a run triggered by an unrelated
 * change (a new event, a task completed elsewhere) keeps the blocks the user is looking at.
 */
export async function runScheduling(
  db: Db,
  config: Pick<Config, 'HORIZON_DAYS'>,
  now: Date = new Date(),
): Promise<SchedulerResult> {
  return db.transaction(async (tx) => {
    // Without this a slow run that read stale tasks could commit after (and overwrite) a newer one.
    await tx.execute(sql.raw(SCHEDULER_LOCK_SQL))
    await materializeRecurringTasks(tx, now, config.HORIZON_DAYS)

    const scheduleRows = await tx.select().from(schedules).where(isNull(schedules.deletedAt))
    const categoryRows = await tx.select().from(categories).where(isNull(categories.deletedAt))
    const taskRows = await tx
      .select()
      .from(tasks)
      .where(and(isNull(tasks.deletedAt), isNull(tasks.completedAt)))
    const eventRows = await tx
      .select(getTableColumns(events))
      .from(events)
      .innerJoin(calendars, eq(events.calendarId, calendars.id))
      .where(and(eq(calendars.selected, true), isNull(events.deletedAt)))
    const previousRows = await tx.select().from(placements)

    const result = schedule(
      buildSchedulerInput({
        now,
        horizonDays: config.HORIZON_DAYS,
        schedules: scheduleRows,
        categories: categoryRows,
        tasks: taskRows,
        events: eventRows,
        previous: previousRows,
      }),
    )

    await tx.delete(placements)
    if (result.placements.length > 0) {
      await tx.insert(placements).values(
        result.placements.map((p) => ({
          id: randomUUID(),
          taskId: p.taskId,
          startAt: new Date(p.start),
          endAt: new Date(p.end),
          pinned: p.pinned,
          computedAt: now,
        })),
      )
    }
    await tx.delete(unscheduled)
    if (result.unscheduled.length > 0) {
      await tx.insert(unscheduled).values(
        result.unscheduled.map((u) => ({
          taskId: u.taskId,
          reason: u.reason,
          unplacedMinutes: u.unplacedMinutes,
          computedAt: now,
        })),
      )
    }
    return result
  })
}
