import { randomUUID } from 'node:crypto'
import { DAY, MINUTE, dateFromDayNumber, dayNumber, isoDate, localDate, schedule, weekdayOf, zonedToUtc } from '@florida/scheduler'
import type { Attention, Interval, Placement, RoutineBlock, SchedulerInput, SchedulerResult, Task } from '@florida/scheduler'
import { and, eq, getTableColumns, gt, gte, isNotNull, isNull, lt, sql } from 'drizzle-orm'
import type { Config } from './config.js'
import type { Db } from './db/client.js'
import { PLAN_SUMMARY_ID, defaultTimeZone } from './db/queries.js'
import {
  calendars,
  categories,
  dayOverrides,
  events,
  optionalPlacements,
  placements,
  planSummary,
  projectPlacements,
  projects,
  routineBlocks,
  routineOccurrences,
  tasks,
  unscheduled,
} from './db/schema.js'
import type {
  CategoryRow,
  DayOverrideRow,
  EventRow,
  PlacementRow,
  ProjectPlacementRow,
  ProjectRow,
  RoutineBlockRow,
  TaskRow,
} from './db/schema.js'
import { materializeRecurringTasks } from './tasks.js'

/** Smallest piece of shared work: long enough for an agent to get somewhere between check-ins. */
export const SHARED_CHUNK_MINUTES = 60
/** Weeks, this one first, that get project time. */
const PROJECT_TIME_WEEKS = 2
/** Less project time than this is not worth a block. */
const MIN_PROJECT_TIME_MINUTES = 30
/** How long ended project time is kept: the weekly review reads the week before. */
const PROJECT_TIME_RETENTION = 14 * DAY

const PROJECT_TIME_PREFIX = 'project-time:'

/** Time reserved for a project beyond its tasks. No task is behind it. */
export interface ProjectTime {
  projectId: string
  /** Local date of the Sunday starting the week whose budget the block draws on. */
  weekOf: string
  start: string
  end: string
  lane?: number
}

/** What a scheduler run produced: the scheduler's result for real tasks, plus project time. */
export interface PlanResult extends SchedulerResult {
  projectPlacements: ProjectTime[]
}

/** The id the scheduler sees for a project's time in one week; never stored or sent to clients. */
function projectTimeId(weekOf: string, projectId: string): string {
  return `${PROJECT_TIME_PREFIX}${weekOf}:${projectId}`
}

function parseProjectTimeId(id: string): { weekOf: string; projectId: string } | undefined {
  if (!id.startsWith(PROJECT_TIME_PREFIX)) return undefined
  const rest = id.slice(PROJECT_TIME_PREFIX.length)
  return { weekOf: rest.slice(0, 10), projectId: rest.slice(11) }
}

/** The Sunday-to-Saturday local week containing `ms`, plus the following `count - 1` weeks. */
export function localWeeks(ms: number, timeZone: string, count: number): { weekOf: string; start: number; end: number }[] {
  const today = localDate(ms, timeZone)
  const sunday = dayNumber(today) - weekdayOf(today)
  return Array.from({ length: count }, (_, i) => {
    const first = dateFromDayNumber(sunday + 7 * i)
    return {
      weekOf: isoDate(first),
      start: zonedToUtc(first, 0, timeZone),
      end: zonedToUtc(dateFromDayNumber(sunday + 7 * (i + 1)), 0, timeZone),
    }
  })
}

/** The attention a task takes: its own setting, else its project's (shared when the project is parallel). */
export function effectiveAttention(task: Pick<TaskRow, 'attention'>, project: Pick<ProjectRow, 'parallel'> | undefined): Attention {
  return task.attention ?? (project?.parallel === true ? 'shared' : 'full')
}

export interface SchedulerSources {
  now: Date
  horizonDays: number
  /** The routine's zone; block times are wall clock in it. */
  timeZone: string
  routineBlocks: RoutineBlockRow[]
  categories: CategoryRow[]
  tasks: TaskRow[]
  events: EventRow[]
  /** The last run's output. Only a block underway at `now` is kept where it was. Omit for a fresh plan. */
  previous?: PlacementRow[]
  projects?: ProjectRow[]
  dayOverrides?: DayOverrideRow[]
  /**
   * Stored project time. Blocks that ended count against their week's budget; one underway goes to
   * the scheduler as a previous placement.
   */
  projectPlacements?: ProjectPlacementRow[]
  /** Tasks with a project completed since the start of this week; their time counts against its budget. */
  completedProjectTasks?: TaskRow[]
}

/**
 * Maps database rows to scheduler input. Pure.
 *
 * Live routine blocks become the routine; each task carries its own `context`, and the scheduler
 * places it only in blocks that allow it. A task takes its `area` from its category, which orders
 * the suggestions for optional blocks. Tasks that are deleted, completed, or belong to a
 * deleted category are skipped. Busy time is every live, timed, opaque, not-declined event from
 * the Sunday of the current week to the horizon: the earlier days decide where this week's
 * commitments landed (a gym session that moved off a booked Tuesday morning stays moved once the
 * meeting is over).
 *
 * Of the previous placements only the blocks underway at `now` go through, so work the user is
 * in the middle of stays where it is. Everything still ahead is planned afresh on every run:
 * that is what moves a task when its priority, deadline or length changes, and moves the work
 * behind it up when a task is finished or a meeting is cancelled.
 *
 * Projects: a task of a live project that is not `active` is skipped, so it waits unplaced until
 * the project is picked up again. A task's attention defaults from its project, and shared work
 * without a chunk size of its own splits into `SHARED_CHUNK_MINUTES` pieces. An active project
 * with a weekly budget gets a synthetic task per week for the part of the budget that its tasks
 * and the time already spent do not cover (see `projectTimeTasks`); `splitProjectTime` takes
 * those back out of the result.
 */
export function buildSchedulerInput(src: SchedulerSources): SchedulerInput {
  const nowMs = src.now.getTime()
  const horizonEnd = nowMs + src.horizonDays * DAY
  const weekStart = localWeeks(nowMs, src.timeZone, 1)[0]?.start ?? nowMs
  const underway = (p: { startAt: Date; endAt: Date }): boolean => p.startAt.getTime() <= nowMs && p.endAt.getTime() > nowMs

  const blocks: RoutineBlock[] = src.routineBlocks
    .filter((b) => b.deletedAt === null)
    .map((b) => ({
      id: b.id,
      days: b.days,
      start: b.start,
      end: b.end,
      allows: b.allows,
      ...(b.optional ? { optional: true } : {}),
      ...(b.alternates !== null && b.alternates.length > 0 ? { alternates: b.alternates } : {}),
    }))

  const liveCategories = new Map(src.categories.filter((p) => p.deletedAt === null).map((p) => [p.id, p]))

  const liveProjects = new Map((src.projects ?? []).filter((p) => p.deletedAt === null).map((p) => [p.id, p]))

  const openTasks: Task[] = []
  /** Minutes of open task work per project, which its weekly budget covers before any project time. */
  const openMinutes = new Map<string, number>()
  for (const t of src.tasks) {
    const category = liveCategories.get(t.categoryId)
    if (t.deletedAt !== null || t.completedAt !== null || category === undefined) continue
    const project = t.projectId === null ? undefined : liveProjects.get(t.projectId)
    if (project !== undefined && project.status !== 'active') continue
    const attention = effectiveAttention(t, project)
    const task: Task = {
      id: t.id,
      context: t.context,
      attention,
      durationMinutes: t.durationMinutes,
      priority: t.priority,
      deadlineType: t.deadlineType,
      completedMinutes: t.completedMinutes,
      createdAt: t.createdAt.toISOString(),
    }
    if (category.area !== null) task.area = category.area
    if (project !== undefined) {
      task.projectId = project.id
      openMinutes.set(project.id, (openMinutes.get(project.id) ?? 0) + Math.max(0, t.durationMinutes - t.completedMinutes))
    }
    if (t.minChunkMinutes !== null) task.minChunkMinutes = t.minChunkMinutes
    else if (attention === 'shared' && t.pinnedStart === null) task.minChunkMinutes = SHARED_CHUNK_MINUTES
    if (t.dueAt !== null) task.dueAt = t.dueAt.toISOString()
    if (t.startAt !== null) task.startAt = t.startAt.toISOString()
    if (t.pinnedStart !== null) task.pinnedStart = t.pinnedStart.toISOString()
    openTasks.push(task)
  }
  openTasks.push(...projectTimeTasks(src, [...liveProjects.values()], liveCategories, openMinutes))

  const busy: Interval[] = []
  for (const e of src.events) {
    if (e.deletedAt !== null || e.status === 'cancelled' || e.allDay) continue
    if (e.transparency === 'transparent' || e.responseStatus === 'declined') continue
    if (e.startAt === null || e.endAt === null) continue
    const start = e.startAt.getTime()
    const end = e.endAt.getTime()
    if (end <= start || end <= weekStart || start >= horizonEnd) continue
    busy.push({ start: e.startAt.toISOString(), end: e.endAt.toISOString() })
  }

  const input: SchedulerInput = {
    now: src.now.toISOString(),
    routine: { timeZone: src.timeZone, blocks },
    tasks: openTasks,
    busy,
    horizonDays: src.horizonDays,
  }
  const overrides = (src.dayOverrides ?? []).filter((o) => o.deletedAt === null)
  if (overrides.length > 0) input.dayOverrides = overrides.map((o) => ({ date: o.date, kind: o.kind }))
  if (src.previous !== undefined) {
    input.previous = [
      ...src.previous.filter(underway).map((p) => ({
        taskId: p.taskId,
        start: p.startAt.toISOString(),
        end: p.endAt.toISOString(),
        pinned: p.pinned,
        ...(p.lane !== null ? { lane: p.lane } : {}),
      })),
      ...(src.projectPlacements ?? [])
        .filter(underway)
        .map((p) => ({
          taskId: projectTimeId(p.weekOf, p.projectId),
          start: p.startAt.toISOString(),
          end: p.endAt.toISOString(),
          pinned: false,
          ...(p.lane !== null ? { lane: p.lane } : {}),
        })),
    ]
  }
  return input
}

/**
 * One synthetic task per active budgeted project and week, for the part of the weekly budget
 * nothing else covers. This week's budget is first reduced by what was already spent: project
 * time that has ended and tasks completed since Sunday. Open task work then draws on the budget,
 * this week's first and the overflow from next week's. What is left, rounded down to a quarter
 * hour, becomes low-priority work due by the end of its week, never started before it.
 */
function projectTimeTasks(
  src: SchedulerSources,
  liveProjects: ProjectRow[],
  liveCategories: Map<string, CategoryRow>,
  openMinutes: Map<string, number>,
): Task[] {
  const nowMs = src.now.getTime()
  const weeks = localWeeks(nowMs, src.timeZone, PROJECT_TIME_WEEKS)
  const thisWeek = weeks[0]
  if (thisWeek === undefined) return []
  const out: Task[] = []
  for (const project of liveProjects) {
    if (project.status !== 'active' || project.weeklyMinutes === null || project.weeklyMinutes <= 0) continue
    let spent = 0
    for (const p of src.projectPlacements ?? []) {
      if (p.projectId !== project.id || p.weekOf !== thisWeek.weekOf || p.endAt.getTime() > nowMs) continue
      spent += (p.endAt.getTime() - p.startAt.getTime()) / MINUTE
    }
    for (const t of src.completedProjectTasks ?? []) {
      if (t.projectId !== project.id || t.deletedAt !== null || t.completedAt === null) continue
      if (t.completedAt.getTime() >= thisWeek.start) spent += t.durationMinutes
    }
    let owed = openMinutes.get(project.id) ?? 0
    const area = project.categoryId === null ? undefined : liveCategories.get(project.categoryId)?.area
    weeks.forEach((week, i) => {
      const budget = Math.max(0, project.weeklyMinutes! - (i === 0 ? spent : 0))
      const covered = Math.min(budget, owed)
      owed -= covered
      const minutes = Math.floor((budget - covered) / 15) * 15
      if (minutes < MIN_PROJECT_TIME_MINUTES) return
      const task: Task = {
        id: projectTimeId(week.weekOf, project.id),
        context: 'computer',
        attention: project.parallel ? 'shared' : 'full',
        projectId: project.id,
        durationMinutes: minutes,
        minChunkMinutes: Math.min(SHARED_CHUNK_MINUTES, minutes),
        priority: 'low',
        deadlineType: 'soft',
        dueAt: new Date(week.end).toISOString(),
        createdAt: project.createdAt.toISOString(),
      }
      if (area != null) task.area = area
      if (i > 0) task.startAt = new Date(week.start).toISOString()
      out.push(task)
    })
  }
  return out
}

/**
 * Takes the synthetic project-time tasks back out of a scheduler result. Their blocks become
 * `projectPlacements`, except blocks the scheduler could only fit after their own week: a week's
 * budget is not carried into the next. Project time is never reported unscheduled or late, and
 * is never suggested for an optional block.
 */
export function splitProjectTime(result: SchedulerResult, timeZone: string): PlanResult {
  const isReal = (taskId: string) => !taskId.startsWith(PROJECT_TIME_PREFIX)
  const projectTime: ProjectTime[] = []
  const real: Placement[] = []
  for (const p of result.placements) {
    const parsed = parseProjectTimeId(p.taskId)
    if (parsed === undefined) {
      real.push(p)
      continue
    }
    const week = localWeeks(new Date(p.start).getTime(), timeZone, 1)[0]
    if (week?.weekOf !== parsed.weekOf) continue
    projectTime.push({ ...parsed, start: p.start, end: p.end, ...(p.lane !== undefined ? { lane: p.lane } : {}) })
  }
  return {
    ...result,
    placements: real,
    unscheduled: result.unscheduled.filter((u) => isReal(u.taskId)),
    late: result.late.filter((l) => isReal(l.taskId)),
    optional: result.optional.filter((o) => isReal(o.taskId)),
    projectPlacements: projectTime,
  }
}

/** Arbitrary constant; serializes scheduler runs across processes via a transaction-scoped advisory lock. */
const SCHEDULER_LOCK_SQL = 'select pg_advisory_xact_lock(731104)'

/**
 * Loads the current state, runs the scheduler, and replaces its stored output (`placements`,
 * `unscheduled`, `optional_placements`, `routine_occurrences`, `plan_summary` and the
 * `project_placements` that have not ended) inside one transaction. Returns the result so
 * callers can relay it.
 *
 * The outgoing `placements` rows are fed back as `previous`, so a block the user is in the middle
 * of does not creep forward to the next grid point on every run. Blocks still ahead are planned
 * afresh (see `buildSchedulerInput`), as are the suggestions for optional blocks.
 */
export async function runScheduling(
  db: Db,
  config: Pick<Config, 'HORIZON_DAYS'>,
  now: Date = new Date(),
): Promise<PlanResult> {
  return db.transaction(async (tx) => {
    // Without this a slow run that read stale tasks could commit after (and overwrite) a newer one.
    await tx.execute(sql.raw(SCHEDULER_LOCK_SQL))
    await materializeRecurringTasks(tx, now, config.HORIZON_DAYS)

    const timeZone = await defaultTimeZone(tx)
    const blockRows = await tx.select().from(routineBlocks).where(isNull(routineBlocks.deletedAt))
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
    const projectRows = await tx.select().from(projects).where(isNull(projects.deletedAt))
    const overrideRows = await tx.select().from(dayOverrides).where(isNull(dayOverrides.deletedAt))
    await tx.delete(projectPlacements).where(lt(projectPlacements.endAt, new Date(now.getTime() - PROJECT_TIME_RETENTION)))
    const projectPlacementRows = await tx.select().from(projectPlacements)
    const weekStart = localWeeks(now.getTime(), timeZone, 1)[0]?.start ?? now.getTime()
    const completedProjectTasks = await tx
      .select()
      .from(tasks)
      .where(and(isNull(tasks.deletedAt), isNotNull(tasks.projectId), gte(tasks.completedAt, new Date(weekStart))))

    const result = splitProjectTime(
      schedule(
        buildSchedulerInput({
          projects: projectRows,
          dayOverrides: overrideRows,
          projectPlacements: projectPlacementRows,
          completedProjectTasks,
          now,
          horizonDays: config.HORIZON_DAYS,
          timeZone,
          routineBlocks: blockRows,
          categories: categoryRows,
          tasks: taskRows,
          events: eventRows,
          previous: previousRows,
        }),
      ),
      timeZone,
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
          lane: p.lane ?? null,
          computedAt: now,
        })),
      )
    }
    // Ended blocks are the record of time spent; everything else is this run's to replace.
    await tx.delete(projectPlacements).where(gt(projectPlacements.endAt, now))
    if (result.projectPlacements.length > 0) {
      await tx.insert(projectPlacements).values(
        result.projectPlacements.map((p) => ({
          id: randomUUID(),
          projectId: p.projectId,
          weekOf: p.weekOf,
          startAt: new Date(p.start),
          endAt: new Date(p.end),
          lane: p.lane ?? null,
          computedAt: now,
        })),
      )
    }
    await tx.delete(routineOccurrences)
    if (result.routine.length > 0) {
      await tx.insert(routineOccurrences).values(
        result.routine.map((o) => ({
          id: randomUUID(),
          blockId: o.blockId,
          startAt: new Date(o.start),
          endAt: new Date(o.end),
          computedAt: now,
        })),
      )
    }
    const summary = { missed: result.missed, capacity: result.capacity, computedAt: now }
    await tx
      .insert(planSummary)
      .values({ id: PLAN_SUMMARY_ID, ...summary })
      .onConflictDoUpdate({ target: planSummary.id, set: summary })
    await tx.delete(optionalPlacements)
    if (result.optional.length > 0) {
      await tx.insert(optionalPlacements).values(
        result.optional.map((p) => ({
          id: randomUUID(),
          taskId: p.taskId,
          blockId: p.blockId,
          startAt: new Date(p.start),
          endAt: new Date(p.end),
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
