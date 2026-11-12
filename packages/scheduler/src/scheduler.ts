import type {
  DayCapacity,
  DayKind,
  DayOverride,
  Late,
  MissedCommitment,
  OptionalPlacement,
  Placement,
  Priority,
  Routine,
  RoutineOccurrence,
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
  isoDate,
  localDate,
  parseClock,
  weekdayOf,
  zonedToUtc,
} from './time.js'
import { type Span, addSpan, mergeSpans, subtractSpans } from './intervals.js'

const PRIORITY_RANK: Record<Priority, number> = { asap: 0, high: 1, medium: 2, low: 3 }

const CONTEXTS: TaskContext[] = ['computer', 'errand', 'home', 'office']
const CAPACITY_DAYS = 7

interface Context {
  now: number
  horizonEnd: number
  granularity: number
  overflow: { start: string; end: string }
  /** The weekday whose routine applies on a date, or undefined on a day off. See `DayOverride`. */
  weekdayFor: (date: LocalDate) => number | undefined
}

/** A placed block and the lane it is in; full-attention work is always in lane 0. */
interface Piece extends Span {
  lane: number
}

interface SharedSpan extends Span {
  /** Shared work with the same group never overlaps: the project, or the task when it has none. */
  group: string
}

/**
 * Time already taken. Nothing overlaps `solid`: calendar events, commitments, pinned and
 * full-attention work. Shared-attention work sits in `lanes`, side by side, and only keeps
 * full-attention work and its own group out of the time it covers.
 */
interface Capacity {
  /** Sorted and merged. */
  solid: Span[]
  lanes: SharedSpan[][]
}

const isShared = (task: Task): boolean => task.attention === 'shared' && task.pinnedStart === undefined
const groupOf = (task: Task): string => task.projectId ?? task.id
const overlaps = (a: Span, b: Span): boolean => a.start < b.end && b.start < a.end

/** Every occupied instant in any lane: what full-attention work has to avoid. */
function occupied(cap: Capacity): Span[] {
  return mergeSpans([...cap.solid, ...cap.lanes.flat()])
}

/** What `task` has to avoid in `lane`. Full-attention work has a single lane and avoids everything. */
function takenIn(cap: Capacity, task: Task, lane: number): Span[] {
  if (!isShared(task)) return occupied(cap)
  const group = groupOf(task)
  return mergeSpans([
    ...cap.solid,
    ...cap.lanes.flatMap((spans, index) => (index === lane ? spans : spans.filter((s) => s.group === group))),
  ])
}

function laneCount(cap: Capacity, task: Task): number {
  return isShared(task) ? cap.lanes.length : 1
}

function reserve(cap: Capacity, task: Task, piece: Piece): void {
  const lane = cap.lanes[piece.lane]
  if (isShared(task) && lane !== undefined) lane.push({ start: piece.start, end: piece.end, group: groupOf(task) })
  else cap.solid = addSpan(cap.solid, piece)
}

/** The lane where `span` is free for `task`: `preferred` when it is, else the lowest. */
function freeLane(cap: Capacity, task: Task, span: Span, preferred?: number): number | undefined {
  const lanes = Array.from({ length: laneCount(cap, task) }, (_, lane) => lane)
  if (preferred !== undefined && lanes.includes(preferred)) lanes.unshift(preferred)
  return lanes.find((lane) => !takenIn(cap, task, lane).some((taken) => overlaps(taken, span)))
}

/**
 * The lane of a block already underway, which is never moved. When no lane is free for it (a
 * meeting now covers the block, or stale data has two blocks in one lane) it keeps `preferred`
 * if no other shared work is there, else takes the lowest lane without any.
 */
function activeLane(cap: Capacity, task: Task, span: Span, preferred?: number): number {
  const free = freeLane(cap, task, span, preferred)
  if (free !== undefined || !isShared(task)) return free ?? 0
  const lanes = cap.lanes.map((_, lane) => lane)
  if (preferred !== undefined && lanes.includes(preferred)) lanes.unshift(preferred)
  return lanes.find((lane) => !(cap.lanes[lane] ?? []).some((taken) => overlaps(taken, span))) ?? lanes[0] ?? 0
}

/**
 * The earliest stretch inside `window` where `task` can take at least `need` ms, across its
 * lanes; the lowest lane wins a tie, so shared work stacks side by side from lane 0.
 */
function earliestSlot(
  cap: Capacity,
  task: Task,
  window: Span,
  need: number,
  grid: number,
): { start: number; available: number; lane: number } | undefined {
  let best: { start: number; available: number; lane: number } | undefined
  for (let lane = 0; lane < laneCount(cap, task); lane++) {
    for (const free of subtractSpans(window, takenIn(cap, task, lane))) {
      const start = snapUp(free.start, grid)
      const available = Math.floor((free.end - start) / MINUTE) * MINUTE
      if (available <= 0 || available < need) continue
      if (best === undefined || start < best.start) best = { start, available, lane }
      break
    }
  }
  return best
}

/**
 * Places open tasks into free time. Pure and deterministic: the same input always yields the
 * same output, so it can run anywhere (server, device) and be compared across runs.
 *
 * Order of work: commitments first (the gym, wherever it lands this week), then pinned tasks
 * (they are fixed), then in-progress work is reserved. Flexible tasks sorted by `compareTasks`
 * reuse valid prior blocks before placing their remaining work into the earliest free time
 * inside routine blocks that allow their context. Full-attention work takes its time alone;
 * shared-attention work of up to `maxParallel` different projects runs side by side in lanes.
 * Optional blocks are never part of that plan; `suggestOptional` fills them afterwards.
 */
export function schedule(input: SchedulerInput): SchedulerResult {
  const now = parseInstant(input.now, 'now')
  const ctx: Context = {
    now,
    horizonEnd: now + (input.horizonDays ?? 28) * DAY,
    granularity: (input.granularityMinutes ?? 15) * MINUTE,
    overflow: input.overflowWindow ?? { start: '07:00', end: '23:00' },
    weekdayFor: weekdayResolver(input.routine, input.dayOverrides ?? []),
  }
  const routine = input.routine
  const maxParallel = Math.max(1, Math.floor(input.maxParallel ?? 3))

  const busySpans = input.busy.map((i) => ({
    start: parseInstant(i.start, 'busy.start'),
    end: parseInstant(i.end, 'busy.end'),
  }))
  const open = input.tasks.filter((t) => remainingMinutes(t) > 0)
  const pinned = open.flatMap((task) => {
    if (task.pinnedStart === undefined) return []
    const start = parseInstant(task.pinnedStart, 'pinnedStart')
    return [{ task, span: { start, end: start + remainingMinutes(task) * MINUTE } }]
  })
  const pinnedSpans = pinned.map((p) => p.span)

  // A pinned task takes its time as a meeting does, so a commitment's alternate goes elsewhere.
  const committed = commitments(routine, ctx, [...busySpans, ...pinnedSpans])
  // What an in-progress block gives way to: meetings and commitments that start while it runs.
  const fixedSpans = [...busySpans, ...committed.occurrences]
  const cap: Capacity = {
    solid: mergeSpans([...fixedSpans, ...pinnedSpans]),
    lanes: Array.from({ length: maxParallel }, () => []),
  }
  const placements: Placement[] = pinned.map(({ task, span }) => toPlacement(task, { ...span, lane: 0 }, true))
  const unscheduled: Unscheduled[] = []
  const late: Late[] = []

  const flexible = open
    .filter((t) => t.pinnedStart === undefined)
    .sort((a, b) => compareTasks(a, b, routine.timeZone))

  const previous = new Map<string, Prior[]>(flexible.map((task) => [task.id, []]))
  for (const block of input.previous ?? []) {
    previous.get(block.taskId)?.push({
      start: parseInstant(block.start, 'previous.start'),
      end: parseInstant(block.end, 'previous.end'),
      ...(block.lane === undefined ? {} : { lane: block.lane }),
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
      for (const b of fixedSpans) {
        if (b.end > b.start && b.start > now && b.start < span.end) span.end = b.start
      }
      // Pinned work is the user's explicit choice: a flexible block never runs over it.
      for (const p of pinnedSpans) {
        if (p.end > now && p.start < span.end) span.end = Math.max(now, p.start)
      }
      const ahead = span.end - now
      const piece = { ...span, lane: activeLane(cap, task, span, block.lane) }
      retained.spans.push(piece)
      retained.work += credit + ahead
      reserve(cap, task, piece)
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
      ? placeTask(task, routine, ctx, cap, previous.get(task.id) ?? [], retained)
      : { spans: retained.spans, remaining: Math.max(0, remainingMinutes(task) * MINUTE - retained.work), hardLimited: false }
    plan.set(task.id, { spans: fit.spans, unplaced: fit.remaining })
    for (const piece of fit.spans) placements.push(toPlacement(task, piece, false))

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
  const taken = occupied(cap)
  const optional = suggestOptional(flexible, routine, ctx, taken, plan, input.optionalDays ?? 7)
  const routineOccurrences: RoutineOccurrence[] = committed.occurrences
    .map((o) => ({ blockId: o.blockId, start: toIso(o.start), end: toIso(o.end) }))
    .sort((a, b) => a.start.localeCompare(b.start) || a.blockId.localeCompare(b.blockId))
  return {
    placements,
    unscheduled,
    late,
    optional,
    routine: routineOccurrences,
    missed: committed.missed,
    capacity: capacityByDay(routine, ctx, taken),
  }
}

interface Planned {
  spans: Span[]
  unplaced: number
}

/** A block of the prior run, with the lane it was in when it was shared work. */
interface Prior extends Span {
  lane?: number
}

/**
 * Maps a date to the weekday whose routine it follows. Without an override that is its own
 * weekday; an `off` day follows none; a `home` or `office` day that is not already one follows
 * the first weekday, Monday first, that is.
 */
export function weekdayResolver(routine: Routine, overrides: DayOverride[]): (date: LocalDate) => number | undefined {
  const planned = (weekday: number) => routine.blocks.filter((b) => b.optional !== true && b.days.includes(weekday))
  const kindOf = (weekday: number): DayKind => {
    const blocks = planned(weekday)
    if (blocks.some((b) => b.allows.includes('office'))) return 'office'
    return blocks.some((b) => b.allows.length > 0) ? 'home' : 'off'
  }
  const kinds = new Map(overrides.map((o) => [o.date, o.kind]))
  return (date) => {
    const weekday = weekdayOf(date)
    const kind = kinds.get(isoDate(date))
    if (kind === undefined) return weekday
    if (kind === 'off') return undefined
    if (kindOf(weekday) === kind) return weekday
    return [1, 2, 3, 4, 5, 6, 0].find((candidate) => kindOf(candidate) === kind) ?? weekday
  }
}

/**
 * Occurrences of every commitment, week by week from the Sunday of the current week to the
 * horizon: one per day in `days`, plus one in the earliest of its `alternates` that no busy
 * interval overlaps. Past days of the current week are included so a client can draw the whole
 * week; pass that week's earlier busy time for them to land where they did.
 */
function commitments(
  routine: Routine,
  ctx: Context,
  busy: Span[],
): { occurrences: (Span & { blockId: string })[]; missed: MissedCommitment[] } {
  const occurrences: (Span & { blockId: string })[] = []
  const missed: MissedCommitment[] = []
  const blocks = routine.blocks.filter((b) => b.allows.length === 0 && b.optional !== true)
  if (blocks.length === 0) return { occurrences, missed }

  const today = dayNumber(localDate(ctx.now, routine.timeZone))
  const lastDay = dayNumber(localDate(ctx.horizonEnd, routine.timeZone))
  for (let sunday = today - weekdayOf(dateFromDayNumber(today)); sunday <= lastDay; sunday += 7) {
    const week = Array.from({ length: 7 }, (_, offset) => dateFromDayNumber(sunday + offset))
    for (const block of blocks) {
      for (const date of week) {
        const weekday = ctx.weekdayFor(date)
        if (weekday === undefined || !block.days.includes(weekday)) continue
        occurrences.push({ blockId: block.id, ...windowSpan(date, block.start, block.end, routine.timeZone) })
      }
      const alternates = block.alternates ?? []
      if (alternates.length === 0) continue
      const free = alternates
        .flatMap((slot) =>
          week
            .filter((date) => ctx.weekdayFor(date) === slot.day)
            .map((date) => windowSpan(date, slot.start, slot.end, routine.timeZone)),
        )
        .sort((a, b) => a.start - b.start)
        .find((span) => span.end > span.start && !busy.some((b) => overlaps(b, span)))
      if (free === undefined) missed.push({ blockId: block.id, weekOf: isoDate(dateFromDayNumber(sunday)) })
      else occurrences.push({ blockId: block.id, ...free })
    }
  }
  return { occurrences, missed }
}

/** Free minutes left on each of the next days, per context, once the plan is in. */
function capacityByDay(routine: Routine, ctx: Context, taken: Span[]): DayCapacity[] {
  const firstDay = dayNumber(localDate(ctx.now, routine.timeZone))
  const days: DayCapacity[] = []
  for (let day = firstDay; day < firstDay + CAPACITY_DAYS; day++) {
    const date = dateFromDayNumber(day)
    const freeMinutes = { computer: 0, errand: 0, home: 0, office: 0 }
    for (const context of CONTEXTS) {
      for (const window of blocksOn(routine, ctx, context, date)) {
        const open = { start: Math.max(window.start, ctx.now), end: window.end }
        if (open.end <= open.start) continue
        for (const free of subtractSpans(open, taken)) freeMinutes[context] += Math.floor((free.end - free.start) / MINUTE)
      }
    }
    days.push({ date: isoDate(date), freeMinutes })
  }
  return days
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
    // Optional time keeps its own weekday on a home or office day; a day off has none.
    if (ctx.weekdayFor(date) === undefined) continue
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
  spans: Piece[]
  remaining: number
  /** True when the search was cut off by a hard deadline inside the horizon. */
  hardLimited: boolean
}

/** In-progress blocks kept from the prior run, and the work (ms) they account for. */
interface Retained {
  spans: Piece[]
  /** Elapsed time credited as worked plus the time the kept blocks still cover after `now`. */
  work: number
}

/** Places what is left of `task`, reserving each block in `cap`. */
function placeTask(
  task: Task,
  routine: Routine,
  ctx: Context,
  cap: Capacity,
  previous: Prior[],
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

  let remaining = Math.max(0, remainingMinutes(task) * MINUTE - retained.work)
  const spans: Piece[] = [...retained.spans]

  for (const span of previous) {
    const duration = span.end - span.start
    if (duration <= 0 || duration > remaining || span.start < earliest || span.end > limit) continue
    const windows = blocksOn(routine, ctx, task.context, localDate(span.start, routine.timeZone))
    if (!windows.some((window) => window.start <= span.start && span.end <= window.end)) continue
    const lane = freeLane(cap, task, span, span.lane)
    if (lane === undefined) continue
    const piece = { start: span.start, end: span.end, lane }
    spans.push(piece)
    reserve(cap, task, piece)
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
        while (remaining > 0) {
          const slot = earliestSlot(cap, task, clipped, Math.min(minChunk, remaining), ctx.granularity)
          if (slot === undefined) break
          const take = Math.min(remaining, slot.available)
          const piece = { start: slot.start, end: slot.start + take, lane: slot.lane }
          spans.push(piece)
          reserve(cap, task, piece)
          remaining -= take
          // The rest of the task follows this piece; a short last piece never slips into a gap before it.
          clipped.start = piece.end
        }
        if (remaining === 0) return
      }
    }
  }

  fill((date) => blocksOn(routine, ctx, task.context, date))
  if (remaining > 0 && hardDue !== undefined) {
    fill((date) => [windowSpan(date, ctx.overflow.start, ctx.overflow.end, routine.timeZone)])
  }

  return {
    spans,
    remaining,
    hardLimited: hardDue !== undefined && hardDue <= ctx.horizonEnd,
  }
}

/**
 * Time on `date` where the plan may put a task of `context`: the union of the non-optional
 * routine blocks that allow it, for the weekday the date follows. Overlapping or touching blocks
 * merge, so a task can span them as one piece.
 */
function blocksOn(routine: Routine, ctx: Context, context: TaskContext, date: LocalDate): Span[] {
  const weekday = ctx.weekdayFor(date)
  if (weekday === undefined) return []
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

function toPlacement(task: Task, piece: Piece, pinned: boolean): Placement {
  const placement: Placement = { taskId: task.id, start: toIso(piece.start), end: toIso(piece.end), pinned }
  if (isShared(task)) placement.lane = piece.lane
  return placement
}

function toIso(ms: number): string {
  return new Date(ms).toISOString()
}

function parseInstant(value: string, field: string): number {
  const ms = Date.parse(value)
  if (Number.isNaN(ms)) throw new RangeError(`Invalid ${field}: ${value}`)
  return ms
}
