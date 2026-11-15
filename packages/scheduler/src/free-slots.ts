import type { DayOverride, Interval, Routine, TaskContext } from './types.js'
import { mergeSpans, subtractSpans } from './intervals.js'
import { schedule, weekdayResolver } from './scheduler.js'
import { MINUTE, dateFromDayNumber, dayNumber, localDate, parseClock, zonedToUtc } from './time.js'

export function findFreeSlots(input: {
  start: string
  end: string
  durationMinutes: number
  context?: TaskContext
  routine: Routine
  busy: Interval[]
  occupied?: Interval[]
  commitments?: Interval[]
  commitmentWindow?: Interval
  dayOverrides?: DayOverride[]
}): Interval[] {
  const start = Date.parse(input.start)
  const end = Date.parse(input.end)
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start || end - start > 31 * 24 * 60 * MINUTE || !Number.isFinite(input.durationMinutes) || input.durationMinutes <= 0) {
    throw new RangeError('Expected a positive duration and a range of at most 31 days')
  }
  const plan = schedule({
    now: input.start, horizonDays: (end - start) / (24 * 60 * MINUTE),
    routine: input.routine, busy: input.busy, tasks: [], dayOverrides: input.dayOverrides ?? [],
  })
  const span = (p: Interval) => ({ start: Date.parse(p.start), end: Date.parse(p.end) })
  const coverage = input.commitmentWindow === undefined ? undefined : span(input.commitmentWindow)
  const commitments = input.commitments === undefined ? plan.routine.map(span) : coverage === undefined ? input.commitments.map(span) : [
    ...plan.routine.flatMap((p) => subtractSpans(span(p), [coverage])),
    ...input.commitments.map(span).map((p) => ({ start: Math.max(p.start, coverage.start), end: Math.min(p.end, coverage.end) })),
  ]
  const taken = mergeSpans([...input.busy.map(span), ...(input.occupied ?? []).map(span), ...commitments])
  const weekdayFor = weekdayResolver(input.routine, input.dayOverrides ?? [])
  const first = dayNumber(localDate(start, input.routine.timeZone))
  const last = dayNumber(localDate(end - 1, input.routine.timeZone))
  const windows = []
  for (let day = first; day <= last; day++) {
    const date = dateFromDayNumber(day)
    const weekday = weekdayFor(date)
    if (weekday === undefined) continue
    for (const block of input.routine.blocks) {
      if (block.optional || !block.days.includes(weekday) || (input.context === undefined ? block.allows.length === 0 : !block.allows.includes(input.context))) continue
      windows.push({
        start: Math.max(start, zonedToUtc(date, parseClock(block.start), input.routine.timeZone)),
        end: Math.min(end, zonedToUtc(date, parseClock(block.end), input.routine.timeZone)),
      })
    }
  }
  return mergeSpans(windows).flatMap((window) => subtractSpans(window, taken))
    .filter((slot) => slot.end - slot.start >= input.durationMinutes * MINUTE)
    .map((slot) => ({ start: new Date(slot.start).toISOString(), end: new Date(slot.end).toISOString() }))
}
