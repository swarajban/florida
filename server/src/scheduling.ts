import { randomUUID } from 'node:crypto'
import { DAY, schedule } from '@florida/scheduler'
import type { Interval, Schedule, SchedulerInput, SchedulerResult, Task } from '@florida/scheduler'
import { and, eq, getTableColumns, isNull, sql } from 'drizzle-orm'
import type { Config } from './config.js'
import type { Db } from './db/client.js'
import { calendars, events, placements, projects, schedules, tasks } from './db/schema.js'
import type { EventRow, ProjectRow, ScheduleRow, TaskRow } from './db/schema.js'

export interface SchedulerSources {
  now: Date
  horizonDays: number
  schedules: ScheduleRow[]
  projects: ProjectRow[]
  tasks: TaskRow[]
  events: EventRow[]
}

/**
 * Maps database rows to scheduler input. Pure.
 *
 * A task uses its own `scheduleId` when set, otherwise its project's. Tasks that are deleted,
 * completed, or belong to a deleted project are skipped. Busy time is every live, timed, opaque,
 * not-declined event that overlaps [now, now + horizon).
 */
export function buildSchedulerInput(src: SchedulerSources): SchedulerInput {
  const nowMs = src.now.getTime()
  const horizonEnd = nowMs + src.horizonDays * DAY

  const liveSchedules: Schedule[] = src.schedules
    .filter((s) => s.deletedAt === null)
    .map((s) => ({ id: s.id, timeZone: s.timeZone, windows: s.windows }))

  const projectSchedule = new Map(
    src.projects.filter((p) => p.deletedAt === null).map((p) => [p.id, p.scheduleId] as const),
  )

  const openTasks: Task[] = []
  for (const t of src.tasks) {
    if (t.deletedAt !== null || t.completedAt !== null) continue
    const projectScheduleId = projectSchedule.get(t.projectId)
    if (projectScheduleId === undefined) continue
    const task: Task = {
      id: t.id,
      scheduleId: t.scheduleId ?? projectScheduleId,
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

  return {
    now: src.now.toISOString(),
    schedules: liveSchedules,
    tasks: openTasks,
    busy,
    horizonDays: src.horizonDays,
  }
}

/** Arbitrary constant; serializes scheduler runs across processes via a transaction-scoped advisory lock. */
const SCHEDULER_LOCK_SQL = 'select pg_advisory_xact_lock(731104)'

/**
 * Loads the current state, runs the scheduler, and replaces the `placements` table with the
 * result inside one transaction. Returns the scheduler result so callers can relay it.
 */
export async function runScheduling(
  db: Db,
  config: Pick<Config, 'HORIZON_DAYS'>,
  now: Date = new Date(),
): Promise<SchedulerResult> {
  return db.transaction(async (tx) => {
    // Without this a slow run that read stale tasks could commit after (and overwrite) a newer one.
    await tx.execute(sql.raw(SCHEDULER_LOCK_SQL))

    const scheduleRows = await tx.select().from(schedules).where(isNull(schedules.deletedAt))
    const projectRows = await tx.select().from(projects).where(isNull(projects.deletedAt))
    const taskRows = await tx
      .select()
      .from(tasks)
      .where(and(isNull(tasks.deletedAt), isNull(tasks.completedAt)))
    const eventRows = await tx
      .select(getTableColumns(events))
      .from(events)
      .innerJoin(calendars, eq(events.calendarId, calendars.id))
      .where(and(eq(calendars.selected, true), isNull(events.deletedAt)))

    const result = schedule(
      buildSchedulerInput({
        now,
        horizonDays: config.HORIZON_DAYS,
        schedules: scheduleRows,
        projects: projectRows,
        tasks: taskRows,
        events: eventRows,
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
    return result
  })
}
