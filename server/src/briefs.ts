import { randomUUID } from 'node:crypto'
import { DAY, MINUTE, dateFromDayNumber, dayNumber, isoDate, localDate, localParts, parseClock, weekdayOf, weekdayResolver, zonedToUtc } from '@florida/scheduler'
import type { LocalDate } from '@florida/scheduler'
import { and, asc, desc, eq, getTableColumns, gt, gte, isNotNull, isNull, lt, or } from 'drizzle-orm'
import type { BriefWriter, PlacementExplainer } from './ai/brief.js'
import type { Db } from './db/client.js'
import { defaultTimeZone } from './db/queries.js'
import {
  briefs,
  calendars,
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
import type { BriefKind, BriefRow, ProjectRow, RoutineBlockRow, TaskRow } from './db/schema.js'
import { blockingEventInterval, effectiveAttention, localWeeks } from './scheduling.js'
import { automaticDayReason } from './all-day-blocking.js'
import { getTask } from './tasks.js'
import { parseCalendarDate } from './validation.js'

const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

/** Local minute of the day from which the daily brief is written. */
const DAILY_AT = 8 * 60 + 30
/** Local minute of Sunday from which the weekly review is written. */
const WEEKLY_AT = 18 * 60

/** "09:30" in `timeZone`. */
function clock(instant: Date, timeZone: string): string {
  const p = localParts(instant.getTime(), timeZone)
  return `${String(p.hour).padStart(2, '0')}:${String(p.minute).padStart(2, '0')}`
}

/** "Tue 2026-11-10 09:30" in `timeZone`, for facts that span days. */
function stamp(instant: Date, timeZone: string): string {
  const date = localDate(instant.getTime(), timeZone)
  return `${(WEEKDAYS[weekdayOf(date)] ?? '').slice(0, 3)} ${isoDate(date)} ${clock(instant, timeZone)}`
}

const minutesBetween = (start: Date, end: Date): number => Math.round((end.getTime() - start.getTime()) / MINUTE)

/** What a date is: its override, else what its weekday's planned blocks make it. */
function dayKind(date: string, weekday: number, blocks: RoutineBlockRow[], overrides: Map<string, string>): string {
  const override = overrides.get(date)
  if (override !== undefined) return override
  const planned = blocks.filter((b) => !b.optional && b.allows.length > 0 && b.days.includes(weekday))
  if (planned.some((b) => b.allows.includes('office'))) return 'office'
  return planned.length > 0 ? 'home' : 'no planned hours'
}

/** Everything the briefs and explanations are written from, read in one go. */
async function loadPlan(db: Db, now: Date) {
  const timeZone = await defaultTimeZone(db)
  const today = localDate(now.getTime(), timeZone)
  const projectRows = await db.select().from(projects).where(isNull(projects.deletedAt)).orderBy(projects.sortOrder, projects.name)
  const openTasks = await db
    .select()
    .from(tasks)
    .where(and(isNull(tasks.deletedAt), isNull(tasks.completedAt)))
  const [summary] = await db.select().from(planSummary)
  const overrideRows = await db.select().from(dayOverrides).where(isNull(dayOverrides.deletedAt))
  const horizonEnd = now.getTime() + 28 * DAY
  const busyRows = await db.select(getTableColumns(events)).from(events)
    .innerJoin(calendars, eq(events.calendarId, calendars.id))
    .where(and(eq(calendars.blocksScheduling, true), isNull(events.deletedAt),
      gt(events.endAt, new Date(now.getTime() - DAY)), lt(events.startAt, new Date(horizonEnd + DAY))))
    .orderBy(asc(events.startAt))
  return {
    timeZone,
    now: now.getTime(),
    horizonEnd,
    busyEvents: busyRows.flatMap((e) => {
      const interval = blockingEventInterval(e, timeZone)
      return interval === undefined ? [] : [{ title: e.summary ?? '(no title)', start: Date.parse(interval.start), end: Date.parse(interval.end),
        ...(e.allDay && e.blocksDay === null && e.blockingReason !== null ? { blockingReason: automaticDayReason(e) } : {}) }]
    }),
    today,
    todayKey: isoDate(today),
    blocks: await db.select().from(routineBlocks).where(isNull(routineBlocks.deletedAt)),
    projects: new Map(projectRows.map((p) => [p.id, p])),
    projectRows,
    openTasks: new Map(openTasks.map((t) => [t.id, t])),
    placements: await db.select().from(placements).orderBy(asc(placements.startAt)),
    projectTime: await db.select().from(projectPlacements).orderBy(asc(projectPlacements.startAt)),
    occurrences: await db.select().from(routineOccurrences).orderBy(asc(routineOccurrences.startAt)),
    unscheduled: await db.select().from(unscheduled),
    missed: summary?.missed ?? [],
    capacity: summary?.capacity ?? [],
    overrides: new Map(overrideRows.map((o) => [o.date, o.kind as string])),
    overrideRows,
  }
}

type Plan = Awaited<ReturnType<typeof loadPlan>>

function calendarBusyTime(task: TaskRow, plan: Plan, before = plan.horizonEnd) {
  const start = Math.max(plan.now, task.startAt?.getTime() ?? plan.now)
  const end = Math.min(before, task.deadlineType === 'hard' ? task.dueAt?.getTime() ?? before : before)
  const resolveWeekday = weekdayResolver({ timeZone: plan.timeZone, blocks: plan.blocks.map((b) => ({
    id: b.id, days: b.days, start: b.start, end: b.end, allows: b.allows, optional: b.optional,
  })) }, plan.overrideRows.map((o) => ({ date: o.date, kind: o.kind })))
  const relevant = plan.busyEvents.filter((event) => {
    if (event.end <= start || event.start >= end) return false
    const first = dayNumber(localDate(Math.max(start, event.start), plan.timeZone))
    const last = dayNumber(localDate(Math.min(end, event.end) - 1, plan.timeZone))
    for (let day = first; day <= last; day++) {
      const date = dateFromDayNumber(day)
      const weekday = resolveWeekday(date)
      if (weekday === undefined) continue
      for (const block of plan.blocks) {
        if (block.optional || !block.days.includes(weekday) || !block.allows.includes(task.context)) continue
        const a = zonedToUtc(date, parseClock(block.start), plan.timeZone)
        const b = zonedToUtc(date, parseClock(block.end), plan.timeZone)
        if (Math.max(start, a, event.start) < Math.min(end, b, event.end)) return true
      }
    }
    return false
  })
  const unique = [...new Map(relevant.map((e) => [`${e.title}\0${e.start}\0${e.end}`, e])).values()]
  return { count: unique.length, first: unique.slice(0, FACT_LIST_LIMIT).map((e) => ({ title: e.title, start: stamp(new Date(e.start), plan.timeZone), end: stamp(new Date(e.end), plan.timeZone),
    ...(e.blockingReason === undefined ? {} : { blockingReason: e.blockingReason }) })) }
}

function taskFact(task: TaskRow, plan: Plan) {
  const project = task.projectId === null ? undefined : plan.projects.get(task.projectId)
  return {
    title: task.title,
    priority: task.priority,
    ...(project !== undefined ? { project: project.name } : {}),
    ...(task.dueAt !== null && task.deadlineType !== 'none'
      ? { due: stamp(task.dueAt, plan.timeZone), deadline: task.deadlineType }
      : {}),
  }
}

/** Open dated tasks that are past due, or whose last planned block ends after they are due. */
/**
 * How many entries of a list that grows with the backlog go to the model. The count goes with
 * them, so a brief can still say how many there are.
 */
const FACT_LIST_LIMIT = 10

/** Tasks past their deadline or planned to finish after it, the longest overdue first. */
function lateFacts(plan: Plan, now: Date) {
  const eta = new Map<string, Date>()
  for (const p of plan.placements) eta.set(p.taskId, p.endAt)
  const late = [...plan.openTasks.values()]
    .filter((t) => t.dueAt !== null && t.deadlineType !== 'none')
    .filter((t) => t.dueAt!.getTime() < now.getTime() || (eta.get(t.id)?.getTime() ?? 0) > t.dueAt!.getTime())
    .sort((a, b) => a.dueAt!.getTime() - b.dueAt!.getTime() || a.id.localeCompare(b.id))
  return {
    late: late
      .slice(0, FACT_LIST_LIMIT)
      .map((t) => ({ ...taskFact(t, plan), ...(eta.has(t.id) ? { plannedToFinish: stamp(eta.get(t.id)!, plan.timeZone) } : {}) })),
    lateCount: late.length,
  }
}

/** Tasks the plan has no room for, the most unplaced time first. */
function unscheduledFacts(plan: Plan) {
  const all = plan.unscheduled
    .flatMap((u) => {
      const task = plan.openTasks.get(u.taskId)
      return task === undefined ? [] : [{ title: task.title, reason: u.reason, unplacedMinutes: u.unplacedMinutes, calendarBusyTime: calendarBusyTime(task, plan) }]
    })
    .sort((a, b) => b.unplacedMinutes - a.unplacedMinutes || a.title.localeCompare(b.title))
  return { unscheduled: all.slice(0, FACT_LIST_LIMIT), unscheduledCount: all.length }
}

/**
 * Events of one local day. Timed events are compared against the zoned day; all-day events are
 * stored at UTC midnight of their calendar date, so they are compared against the UTC day.
 */
async function eventsOn(db: Db, day: LocalDate, timeZone: string) {
  const next = dateFromDayNumber(dayNumber(day) + 1)
  const utc = (d: LocalDate) => new Date(Date.UTC(d.year, d.month - 1, d.day))
  const rows = await db
    .select(getTableColumns(events))
    .from(events)
    .innerJoin(calendars, eq(events.calendarId, calendars.id))
    .where(
      and(
        eq(calendars.selected, true),
        isNull(events.deletedAt),
        or(
          and(eq(events.allDay, false), lt(events.startAt, new Date(zonedToUtc(next, 0, timeZone))), gt(events.endAt, new Date(zonedToUtc(day, 0, timeZone)))),
          and(eq(events.allDay, true), lt(events.startAt, utc(next)), gt(events.endAt, utc(day))),
        ),
      ),
    )
    .orderBy(asc(events.startAt))
  return rows.filter((e) => e.status !== 'cancelled' && e.responseStatus !== 'declined' && e.startAt !== null && e.endAt !== null)
}

/** The facts of one local day (the day containing `now`), for the morning brief. */
export async function dailyFacts(db: Db, now: Date = new Date()) {
  const plan = await loadPlan(db, now)
  const { timeZone, today, todayKey } = plan
  const start = zonedToUtc(today, 0, timeZone)
  const end = zonedToUtc(dateFromDayNumber(dayNumber(today) + 1), 0, timeZone)
  const isToday = (d: Date) => d.getTime() >= start && d.getTime() < end
  const week = localWeeks(now.getTime(), timeZone, 1)[0]
  const eventRows = await eventsOn(db, today, timeZone)
  const evening = await db.select().from(optionalPlacements).orderBy(asc(optionalPlacements.startAt))
  const gymBlocks = new Map(plan.blocks.filter((b) => b.allows.length === 0).map((b) => [b.id, b.name]))

  return {
    date: todayKey,
    weekday: WEEKDAYS[weekdayOf(today)],
    writtenAt: clock(now, timeZone),
    day: dayKind(todayKey, weekdayOf(today), plan.blocks, plan.overrides),
    dayNote: plan.overrideRows.find((o) => o.date === todayKey)?.note ?? null,
    gym: {
      today: plan.occurrences
        .filter((o) => isToday(o.startAt))
        .map((o) => ({ name: gymBlocks.get(o.blockId) ?? 'Commitment', start: clock(o.startAt, timeZone), end: clock(o.endAt, timeZone) })),
      restOfWeek: plan.occurrences
        .filter((o) => o.startAt.getTime() >= end && week !== undefined && o.startAt.getTime() < week.end)
        .map((o) => stamp(o.startAt, timeZone)),
      missedThisWeek: week !== undefined && plan.missed.some((m) => m.weekOf === week.weekOf),
    },
    allDay: eventRows.filter((e) => e.allDay).map((e) => e.summary ?? '(no title)'),
    meetings: eventRows
      .filter((e) => !e.allDay)
      .map((e) => ({ title: e.summary ?? '(no title)', start: clock(e.startAt!, timeZone), end: clock(e.endAt!, timeZone) })),
    plan: plan.placements
      .filter((p) => isToday(p.startAt))
      .flatMap((p) => {
        const task = plan.openTasks.get(p.taskId)
        if (task === undefined) return []
        return [{ ...taskFact(task, plan), start: clock(p.startAt, timeZone), end: clock(p.endAt, timeZone), ...(p.lane !== null ? { lane: p.lane } : {}) }]
      }),
    projectTime: plan.projectTime
      .filter((p) => isToday(p.startAt))
      .map((p) => ({
        project: plan.projects.get(p.projectId)?.name ?? 'Project',
        start: clock(p.startAt, timeZone),
        end: clock(p.endAt, timeZone),
        ...(p.lane !== null ? { lane: p.lane } : {}),
      })),
    ...lateFacts(plan, now),
    ...unscheduledFacts(plan),
    freeMinutesToday: plan.capacity.find((c) => c.date === todayKey)?.freeMinutes ?? null,
    evening: evening.filter((o) => isToday(o.startAt)).flatMap((o) => {
      const task = plan.openTasks.get(o.taskId)
      return task === undefined ? [] : [{ title: task.title, minutes: minutesBetween(o.startAt, o.endAt) }]
    }),
  }
}

/** The Sunday a weekly review written at `now` is filed under: last week's on a Sunday, else this week's. */
export function reviewWeekOf(now: Date, timeZone: string): string {
  const today = localDate(now.getTime(), timeZone)
  const weekday = weekdayOf(today)
  return isoDate(dateFromDayNumber(dayNumber(today) - (weekday === 0 ? 7 : weekday)))
}

/**
 * The facts of one week for the review: the week that just ended when written on a Sunday,
 * otherwise the current week so far. Time spent on a project is what the store can vouch for:
 * its tasks completed in the week, and project time whose block has ended.
 */
export async function weeklyFacts(db: Db, now: Date = new Date()) {
  const plan = await loadPlan(db, now)
  const { timeZone } = plan
  const weekOf = reviewWeekOf(now, timeZone)
  const first = parseCalendarDate(weekOf)
  if (first === undefined) throw new Error(`review week ${weekOf} is not a date`)
  const start = zonedToUtc(first, 0, timeZone)
  const end = zonedToUtc(dateFromDayNumber(dayNumber(first) + 7), 0, timeZone)
  const nextEnd = end + 7 * DAY
  const inWeek = (d: Date) => d.getTime() >= start && d.getTime() < end
  const completed = await db
    .select()
    .from(tasks)
    .where(and(isNull(tasks.deletedAt), isNotNull(tasks.completedAt), gte(tasks.completedAt, new Date(start)), lt(tasks.completedAt, new Date(end))))

  const projectFacts = (project: ProjectRow) => {
    const done = completed.filter((t) => t.projectId === project.id)
    const projectTimeSpent = plan.projectTime
      .filter((p) => p.projectId === project.id && inWeek(p.startAt) && p.endAt.getTime() <= now.getTime())
      .reduce((sum, p) => sum + minutesBetween(p.startAt, p.endAt), 0)
    const open = [...plan.openTasks.values()].filter((t) => t.projectId === project.id)
    return {
      name: project.name,
      status: project.status,
      parallel: project.parallel,
      weeklyBudgetMinutes: project.weeklyMinutes,
      minutesSpent: projectTimeSpent + done.reduce((sum, t) => sum + t.durationMinutes, 0),
      tasksCompleted: done.length,
      openTasks: open.length,
      nextStep: project.nextStep,
    }
  }
  const hardDeadlines = [...plan.openTasks.values()]
    .filter((t) => t.deadlineType === 'hard' && t.dueAt !== null && t.dueAt.getTime() >= now.getTime() && t.dueAt.getTime() < nextEnd)
    .map((t) => taskFact(t, plan))

  return {
    weekOf,
    writtenAt: stamp(now, timeZone),
    weekIsOver: now.getTime() >= end,
    projects: plan.projectRows.filter((p) => p.status === 'active').map(projectFacts),
    waiting: plan.projectRows.filter((p) => p.status === 'on_hold' || p.status === 'thinking').map((p) => ({ name: p.name, status: p.status })),
    completed: { count: completed.length, titles: completed.slice(0, 12).map((t) => t.title) },
    ...lateFacts(plan, now),
    ...unscheduledFacts(plan),
    ahead: {
      hardDeadlines,
      dayOverrides: plan.overrideRows
        .filter((o) => o.date >= plan.todayKey)
        .map((o) => ({ date: o.date, kind: o.kind, note: o.note })),
      // Commitments are only known from this week's Sunday on, so the review looks ahead at them.
      gym: plan.occurrences
        .filter((o) => o.startAt.getTime() >= now.getTime() && o.startAt.getTime() < nextEnd)
        .map((o) => stamp(o.startAt, timeZone)),
      weeksWithoutOfficeMorningGym: plan.missed.map((m) => m.weekOf),
      freeMinutesByDay: plan.capacity,
    },
  }
}

/** The facts behind one task's place in the plan, for `PlacementExplainer`. Throws 404 for an unknown task. */
export async function explainFacts(db: Db, taskId: string, now: Date = new Date()) {
  const task = await getTask(db, taskId)
  const plan = await loadPlan(db, now)
  const { timeZone } = plan
  const project = task.projectId === null ? undefined : plan.projects.get(task.projectId)
  const mine = plan.placements.filter((p) => p.taskId === taskId)
  const firstStart = mine[0]?.startAt.getTime()
  const ahead =
    firstStart === undefined
      ? []
      : plan.placements
          .filter((p) => p.taskId !== taskId && p.startAt.getTime() < firstStart && p.endAt.getTime() > now.getTime())
          .flatMap((p) => {
            const other = plan.openTasks.get(p.taskId)
            return other === undefined ? [] : [taskFact(other, plan)]
          })
  const beside = mine.flatMap((m) =>
    plan.placements
      .filter((p) => p.taskId !== taskId && p.lane !== null && m.lane !== null && p.startAt < m.endAt && p.endAt > m.startAt)
      .flatMap((p) => {
        const other = plan.openTasks.get(p.taskId)
        return other === undefined ? [] : [other.title]
      }),
  )
  return {
    now: stamp(now, timeZone),
    task: {
      ...taskFact(task, plan),
      context: task.context,
      attention: effectiveAttention(task, project),
      durationMinutes: task.durationMinutes,
      completed: task.completedAt !== null,
      ...(task.startAt !== null ? { notBefore: stamp(task.startAt, timeZone) } : {}),
      ...(task.pinnedStart !== null ? { pinnedTo: stamp(task.pinnedStart, timeZone) } : {}),
      ...(project !== undefined ? { projectStatus: project.status } : {}),
    },
    planned: mine.map((p) => ({ start: stamp(p.startAt, timeZone), end: clock(p.endAt, timeZone), ...(p.lane !== null ? { lane: p.lane } : {}) })),
    unscheduled: plan.unscheduled.find((u) => u.taskId === taskId) ?? null,
    calendarBusyTime: calendarBusyTime(task, plan, firstStart),
    routineHoursAllowingItsContext: plan.blocks
      .filter((b) => !b.optional && b.allows.includes(task.context))
      .map((b) => ({ name: b.name, days: b.days.map((d) => WEEKDAYS[d]), start: b.start, end: b.end })),
    plannedAheadOfIt: { count: ahead.length, first: ahead.slice(0, 8) },
    runsBeside: [...new Set(beside)],
    freeMinutesByDay: plan.capacity,
  }
}

/** Writes (or rewrites) the brief of `kind` for the day or week containing `now` and stores it. */
export async function generateBrief(db: Db, writer: BriefWriter, kind: BriefKind, now: Date = new Date()): Promise<BriefRow> {
  const timeZone = await defaultTimeZone(db)
  const date = kind === 'daily' ? isoDate(localDate(now.getTime(), timeZone)) : reviewWeekOf(now, timeZone)
  const text = await writer.write(kind, kind === 'daily' ? await dailyFacts(db, now) : await weeklyFacts(db, now))
  const fields = { headline: text.headline, body: text.body, updatedAt: now }
  const [row] = await db
    .insert(briefs)
    .values({ id: randomUUID(), kind, date, createdAt: now, ...fields })
    .onConflictDoUpdate({ target: [briefs.kind, briefs.date], set: fields })
    .returning()
  if (row === undefined) throw new Error(`upsert of ${kind} brief ${date} returned no row`)
  return row
}

/**
 * Writes the briefs that are due and missing: today's from 08:30 local, and on a Sunday from
 * 18:00 the review of the week that just ended. Returns what it wrote, so the caller can tell
 * clients to pull. Safe to call often: a brief that exists is left alone.
 */
export async function ensureBriefs(db: Db, writer: BriefWriter, now: Date = new Date()): Promise<BriefRow[]> {
  const timeZone = await defaultTimeZone(db)
  const parts = localParts(now.getTime(), timeZone)
  const minute = parts.hour * 60 + parts.minute
  const exists = async (kind: BriefKind, date: string, since?: Date) =>
    (
      await db
        .select({ id: briefs.id })
        .from(briefs)
        .where(and(eq(briefs.kind, kind), eq(briefs.date, date), since === undefined ? undefined : gte(briefs.updatedAt, since)))
    ).length > 0
  const written: BriefRow[] = []
  if (minute >= DAILY_AT && !(await exists('daily', isoDate(parts)))) written.push(await generateBrief(db, writer, 'daily', now))
  // A review asked for during the week is filed under the same Sunday and covers only part of
  // the week, so it does not stand in for this one: only a review written since the week ended does.
  const weekEnded = new Date(zonedToUtc(parts, 0, timeZone))
  if (weekdayOf(parts) === 0 && minute >= WEEKLY_AT && !(await exists('weekly', reviewWeekOf(now, timeZone), weekEnded))) {
    written.push(await generateBrief(db, writer, 'weekly', now))
  }
  return written
}

/** How long the job leaves the model alone after a brief failed to write. */
const BRIEF_RETRY_AFTER = 60 * MINUTE

/**
 * `ensureBriefs` for the periodic job. The job runs every few minutes, and a brief that failed is
 * still missing on the next run, so a failure is followed by an hour without a request.
 */
export function briefJob(db: Db, writer: BriefWriter): (now?: Date) => Promise<BriefRow[]> {
  let retryAt = 0
  return async (now = new Date()) => {
    if (now.getTime() < retryAt) return []
    try {
      return await ensureBriefs(db, writer, now)
    } catch (err) {
      retryAt = now.getTime() + BRIEF_RETRY_AFTER
      throw err
    }
  }
}

/** The newest brief of each kind, daily first; what `/api/sync` sends. */
export async function latestBriefs(db: Db): Promise<BriefRow[]> {
  const latest = async (kind: BriefKind) => db.select().from(briefs).where(eq(briefs.kind, kind)).orderBy(desc(briefs.date)).limit(1)
  return [...(await latest('daily')), ...(await latest('weekly'))]
}

/** Explains one task's place in the plan. */
export async function explainPlacement(db: Db, explainer: PlacementExplainer, taskId: string, now: Date = new Date()): Promise<string> {
  return explainer.explain(await explainFacts(db, taskId, now))
}
