import type {
  Late,
  OptionalPlacement,
  Placement,
  Priority,
  Routine,
  SchedulerInput,
  SchedulerResult,
  Task,
  TaskContext,
  Unscheduled,
} from './types.js'
import {
  DAY,
  MINUTE,
  type LocalDate,
  dateFromDayNumber,
  dayNumber,
  localDate,
  parseClock,
  weekdayOf,
  zonedToUtc,
} from './time.js'
import { type Span, addSpan, mergeSpans, subtractSpans } from './intervals.js'

const PRIORITY_RANK: Record<Priority, number> = { asap: 0, high: 1, medium: 2, low: 3 }

interface Context {
  now: number
  horizonEnd: number
  granularity: number
  overflow: { start: string; end: string }
}

/**
 * Places open tasks into free time. Pure and deterministic: the same input always yields the
 * same output, so it can run anywhere (server, device) and be compared across runs.
 *
 * Order of work: pinned tasks first (they are fixed), then reserve in-progress work.
 * Flexible tasks sorted by `compareTasks` reuse valid prior blocks before placing their
 * remaining work into the earliest free time inside routine blocks that allow their context.
 * Optional blocks are never part of that plan; `suggestOptional` fills them afterwards.
 */
export function schedule(input: SchedulerInput): SchedulerResult {
  const now = parseInstant(input.now, 'now')
  const ctx: Context = {
    now,
    horizonEnd: now + (input.horizonDays ?? 28) * DAY,
    granularity: (input.granularityMinutes ?? 15) * MINUTE,
    overflow: input.overflowWindow ?? { start: '07:00', end: '23:00' },
  }
  const routine = input.routine

  const busySpans = input.busy.map((i) => ({
    start: parseInstant(i.start, 'busy.start'),
    end: parseInstant(i.end, 'busy.end'),
  }))
  let busy = mergeSpans(busySpans)
  const placements: Placement[] = []
  const unscheduled: Unscheduled[] = []
  const late: Late[] = []

  const open = input.tasks.filter((t) => remainingMinutes(t) > 0)

  const pinnedSpans: Span[] = []
  for (const task of open) {
    if (task.pinnedStart === undefined) continue
    const start = parseInstant(task.pinnedStart, 'pinnedStart')
    const span = { start, end: start + remainingMinutes(task) * MINUTE }
    placements.push(toPlacement(task.id, span, true))
    pinnedSpans.push(span)
    busy = addSpan(busy, span)
  }

  const flexible = open
    .filter((t) => t.pinnedStart === undefined)
    .sort((a, b) => compareTasks(a, b, routine.timeZone))

  const previous = new Map<string, Span[]>(flexible.map((task) => [task.id, []]))
  for (const block of input.previous ?? []) {
    previous.get(block.taskId)?.push({
      start: parseInstant(block.start, 'previous.start'),
      end: parseInstant(block.end, 'previous.end'),
    })
  }

  // Reserve work already underway before new tasks can claim its time.
  const active = new Map<string, Retained>()
  for (const task of flexible) {
    const logged = (task.completedMinutes ?? 0) * MINUTE
    let remaining = remainingMinutes(task) * MINUTE
    const retained: Retained = { spans: [], work: 0 }
    const prior = previous.get(task.id) ?? []
    prior.sort((a, b) => a.start - b.start)
    for (const block of prior) {
      if (remaining <= 0 || block.start > now || block.end <= now) continue
      // Time already spent in the block counts as worked unless the logged minutes cover it, so
      // logging progress mid-block never counts the same minutes twice.
      const credit = Math.max(0, now - block.start - logged)
      remaining = Math.max(0, remaining - credit)
      const span = { start: block.start, end: Math.max(now, Math.min(block.end, now + remaining)) }
      for (const b of busySpans) {
        if (b.end > b.start && b.start > now && b.start < span.end) span.end = b.start
      }
      // Pinned work is the user's explicit choice: a flexible block never runs over it.
      for (const p of pinnedSpans) {
        if (p.end > now && p.start < span.end) span.end = Math.max(now, p.start)
      }
      const ahead = span.end - now
      retained.spans.push(span)
      retained.work += credit + ahead
      busy = addSpan(busy, span)
      remaining -= ahead
    }
    active.set(task.id, retained)
  }

  /** Per task: the blocks the plan gave it and the work (ms) it found no room for. */
  const plan = new Map<string, Planned>()
  for (const task of flexible) {
    const allowed = routine.blocks.some(
      (b) => b.optional !== true && b.allows.includes(task.context) && b.days.length > 0,
    )
    const retained = active.get(task.id) ?? { spans: [], work: 0 }
    const fit: Fit = allowed
      ? placeTask(task, routine, ctx, busy, previous.get(task.id) ?? [], retained)
      : { spans: retained.spans, remaining: Math.max(0, remainingMinutes(task) * MINUTE - retained.work), busy, hardLimited: false }
    busy = fit.busy
    plan.set(task.id, { spans: fit.spans, unplaced: fit.remaining })
    for (const span of fit.spans) placements.push(toPlacement(task.id, span, false))

    if (fit.remaining > 0) {
      unscheduled.push({
        taskId: task.id,
        reason: !allowed ? 'no_allowed_block'
          : fit.hardLimited ? 'no_fit_before_hard_deadline' : 'no_fit_in_horizon',
        unplacedMinutes: fit.remaining / MINUTE,
      })
    }

    const due = effectiveDue(task)
    if (due !== undefined && fit.spans.length > 0) {
      const eta = Math.max(...fit.spans.map((s) => s.end))
      if (eta > due.ms) late.push({ taskId: task.id, dueAt: due.iso, eta: toIso(eta) })
    }
  }

  placements.sort((a, b) => a.start.localeCompare(b.start) || a.taskId.localeCompare(b.taskId))
  const optional = suggestOptional(flexible, routine, ctx, busy, plan, input.optionalDays ?? 7)
  return { placements, unscheduled, late, optional }
}

interface Planned {
  spans: Span[]
  unplaced: number
}

/**
 * Suggestions for the optional blocks of the next `days` local days: what to do there if the user
 * chooses to work. Each block is filled on its own, around busy time and planned blocks, from the
 * work the plan has not finished by the time the block ends: blocks planned after it, and work
 * that found no room. Personal tasks come first, then the rest, each in `compareTasks` order.
 * Nothing here changes the plan, so the same task can be suggested on several days.
 */
function suggestOptional(
  flexible: Task[],
  routine: Routine,
  ctx: Context,
  busy: Span[],
  plan: Map<string, Planned>,
  days: number,
): OptionalPlacement[] {
  // `sort` is stable, so tasks keep their `compareTasks` order within an area.
  const personalFirst = (task: Task): number => (task.area === 'personal' ? 0 : 1)
  const ordered = [...flexible].sort((a, b) => personalFirst(a) - personalFirst(b))
  const suggestions: OptionalPlacement[] = []
  const firstDay = dayNumber(localDate(ctx.now, routine.timeZone))

  for (let day = firstDay; day < firstDay + days; day++) {
    const date = dateFromDayNumber(day)
    const weekday = weekdayOf(date)
    for (const block of routine.blocks) {
      if (block.optional !== true || !block.days.includes(weekday)) continue
      const window = windowSpan(date, block.start, block.end, routine.timeZone)
      let taken = busy
      for (const task of ordered) {
        if (!block.allows.includes(task.context)) continue
        const planned = plan.get(task.id)
        if (planned === undefined) continue
        let work = planned.unplaced
        for (const span of planned.spans) {
          if (span.start >= window.end) work += span.end - span.start
        }
        if (work <= 0) continue

        const minChunk = Math.min((task.minChunkMinutes ?? Number.POSITIVE_INFINITY) * MINUTE, work)
        const hardDue = task.deadlineType === 'hard' ? effectiveDue(task)?.ms : undefined
        const notBefore = task.startAt === undefined ? ctx.now : parseInstant(task.startAt, 'startAt')
        const open = {
          start: Math.max(window.start, ctx.now, notBefore),
          end: Math.min(window.end, hardDue ?? Number.POSITIVE_INFINITY),
        }
        if (open.end <= open.start) continue
        for (const free of subtractSpans(open, taken)) {
          const start = snapUp(free.start, ctx.granularity)
          const available = Math.floor((free.end - start) / MINUTE) * MINUTE
          if (available <= 0 || available < Math.min(minChunk, work)) continue
          const take = Math.min(work, available)
          const span = { start, end: start + take }
          suggestions.push({ taskId: task.id, blockId: block.id, start: toIso(span.start), end: toIso(span.end) })
          taken = addSpan(taken, span)
          work -= take
          if (work === 0) break
        }
      }
    }
  }

  return suggestions.sort((a, b) => a.start.localeCompare(b.start) || a.taskId.localeCompare(b.taskId))
}

/**
 * ASAP first; then earliest due day (no deadline last); hard before soft on the same due day;
 * then priority; then creation time. Earliest-deadline-first maximizes deadlines met, and hard
 * deadlines constrain new blocks, including the overflow pass in `placeTask`.
 */
function compareTasks(a: Task, b: Task, timeZone: string): number {
  const aAsap = a.priority === 'asap'
  const bAsap = b.priority === 'asap'
  if (aAsap !== bAsap) return aAsap ? -1 : 1

  const aDue = dueDay(a, timeZone)
  const bDue = dueDay(b, timeZone)
  if (aDue !== bDue) return aDue < bDue ? -1 : 1
  if (aDue !== Number.POSITIVE_INFINITY && a.deadlineType !== b.deadlineType) {
    return a.deadlineType === 'hard' ? -1 : 1
  }

  const priority = PRIORITY_RANK[a.priority] - PRIORITY_RANK[b.priority]
  if (priority !== 0) return priority

  const created = parseInstant(a.createdAt, 'createdAt') - parseInstant(b.createdAt, 'createdAt')
  if (created !== 0) return created
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
}

interface Fit {
  spans: Span[]
  remaining: number
  busy: Span[]
  /** True when the search was cut off by a hard deadline inside the horizon. */
  hardLimited: boolean
}

/** In-progress blocks kept from the prior run, and the work (ms) they account for. */
interface Retained {
  spans: Span[]
  /** Elapsed time credited as worked plus the time the kept blocks still cover after `now`. */
  work: number
}

function placeTask(
  task: Task,
  routine: Routine,
  ctx: Context,
  initialBusy: Span[],
  previous: Span[],
  retained: Retained,
): Fit {
  const minChunk =
    Math.min(task.minChunkMinutes ?? Number.POSITIVE_INFINITY, remainingMinutes(task)) * MINUTE
  const earliest = Math.max(
    ctx.now,
    task.startAt === undefined ? ctx.now : parseInstant(task.startAt, 'startAt'),
    ...retained.spans.map((span) => span.end),
  )
  const hardDue = task.deadlineType === 'hard' ? effectiveDue(task)?.ms : undefined
  const limit = Math.min(ctx.horizonEnd, hardDue ?? Number.POSITIVE_INFINITY)

  let busy = initialBusy
  let remaining = Math.max(0, remainingMinutes(task) * MINUTE - retained.work)
  const spans: Span[] = [...retained.spans]

  for (const span of previous) {
    const duration = span.end - span.start
    if (duration <= 0 || duration > remaining || span.start < earliest || span.end > limit) continue
    const windows = blocksOn(routine, task.context, localDate(span.start, routine.timeZone))
    if (!windows.some((window) => window.start <= span.start && span.end <= window.end)) continue
    if (busy.some((b) => b.start < span.end && span.start < b.end)) continue
    spans.push(span)
    busy = addSpan(busy, span)
    remaining -= duration
  }

  const fill = (windowsForDay: (date: LocalDate) => Span[]): void => {
    const firstDay = dayNumber(localDate(earliest, routine.timeZone))
    for (let day = firstDay; remaining > 0; day++) {
      const date = dateFromDayNumber(day)
      if (zonedToUtc(date, 0, routine.timeZone) >= limit) break
      for (const window of windowsForDay(date)) {
        const clipped = { start: Math.max(window.start, earliest), end: Math.min(window.end, limit) }
        if (clipped.end <= clipped.start) continue
        for (const free of subtractSpans(clipped, busy)) {
          const start = snapUp(free.start, ctx.granularity)
          const available = Math.floor((free.end - start) / MINUTE) * MINUTE
          if (available <= 0 || available < Math.min(minChunk, remaining)) continue
          const take = Math.min(remaining, available)
          const span = { start, end: start + take }
          spans.push(span)
          busy = addSpan(busy, span)
          remaining -= take
          if (remaining === 0) return
        }
      }
    }
  }

  fill((date) => blocksOn(routine, task.context, date))
  if (remaining > 0 && hardDue !== undefined) {
    fill((date) => [windowSpan(date, ctx.overflow.start, ctx.overflow.end, routine.timeZone)])
  }

  return {
    spans,
    remaining,
    busy,
    hardLimited: hardDue !== undefined && hardDue <= ctx.horizonEnd,
  }
}

/**
 * Time on `date` where the plan may put a task of `context`: the union of the non-optional
 * routine blocks that allow it. Overlapping or touching blocks merge, so a task can span them as
 * one piece.
 */
function blocksOn(routine: Routine, context: TaskContext, date: LocalDate): Span[] {
  const weekday = weekdayOf(date)
  return mergeSpans(
    routine.blocks
      .filter((b) => b.optional !== true && b.days.includes(weekday) && b.allows.includes(context))
      .map((b) => windowSpan(date, b.start, b.end, routine.timeZone)),
  )
}

function windowSpan(date: LocalDate, start: string, end: string, timeZone: string): Span {
  return {
    start: zonedToUtc(date, parseClock(start), timeZone),
    end: zonedToUtc(date, parseClock(end), timeZone),
  }
}

function dueDay(task: Task, timeZone: string): number {
  const due = effectiveDue(task)
  if (due === undefined) return Number.POSITIVE_INFINITY
  return dayNumber(localDate(due.ms, timeZone))
}

function effectiveDue(task: Task): { ms: number; iso: string } | undefined {
  if (task.deadlineType === 'none' || task.dueAt === undefined) return undefined
  return { ms: parseInstant(task.dueAt, 'dueAt'), iso: task.dueAt }
}

function remainingMinutes(task: Task): number {
  return Math.max(0, task.durationMinutes - (task.completedMinutes ?? 0))
}

function snapUp(ms: number, grid: number): number {
  return Math.ceil(ms / grid) * grid
}

function toPlacement(taskId: string, span: Span, pinned: boolean): Placement {
  return { taskId, start: toIso(span.start), end: toIso(span.end), pinned }
}

function toIso(ms: number): string {
  return new Date(ms).toISOString()
}

function parseInstant(value: string, field: string): number {
  const ms = Date.parse(value)
  if (Number.isNaN(ms)) throw new RangeError(`Invalid ${field}: ${value}`)
  return ms
}
