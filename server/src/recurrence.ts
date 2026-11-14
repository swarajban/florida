import { dateFromDayNumber, dayNumber, localDate, localParts, weekdayOf, zonedToUtc } from '@florida/scheduler'
import type { Attention, DeadlineType, Priority, TaskContext } from '@florida/scheduler'
import { z } from 'zod'
import type { TaskSource } from './task-source.js'
import { calendarDate, formatCalendarDate, parseCalendarDate, timeZone } from './validation.js'

/** Calendar-based intervals, not elapsed milliseconds. Weekly intervals use Monday-based weeks. */
export const recurrenceRule = z.object({
  frequency: z.enum(['day', 'week', 'month']),
  interval: z.number().int().min(1).max(999),
  timeZone,
  startDate: calendarDate,
  weekdays: z.array(z.number().int().min(0).max(6)).min(1).max(7).optional(),
  dayOfMonth: z.number().int().min(1).max(31).optional(),
  endDate: calendarDate.nullish(),
}).superRefine((rule, ctx) => {
  if (rule.endDate != null && rule.endDate < rule.startDate) {
    ctx.addIssue({ code: 'custom', path: ['endDate'], message: 'endDate must be on or after startDate' })
  }
  if (rule.weekdays !== undefined && (rule.frequency !== 'week' || new Set(rule.weekdays).size !== rule.weekdays.length)) {
    ctx.addIssue({ code: 'custom', path: ['weekdays'], message: 'weekdays must be unique and only apply to weekly repeats' })
  }
  if (rule.dayOfMonth !== undefined && rule.frequency !== 'month') {
    ctx.addIssue({ code: 'custom', path: ['dayOfMonth'], message: 'dayOfMonth only applies to monthly repeats' })
  }
})
export type RecurrenceRule = z.infer<typeof recurrenceRule>

/** Server-owned series template; dates are wall-clock offsets from anchorDate in the rule's zone. */
export interface RecurringTaskTemplate {
  anchorDate: string
  categoryId: string
  title: string
  notes: string | null
  source?: TaskSource | null
  durationMinutes: number
  minChunkMinutes: number | null
  priority: Priority
  deadlineType: DeadlineType
  dueAt: string | null
  someday: boolean
  startAt: string | null
  scheduleId: string | null
  context: TaskContext
  projectId: string | null
  attention: Attention | null
  pinnedStart: string | null
}

function date(value: string) {
  const parsed = parseCalendarDate(value)
  if (parsed === undefined) throw new RangeError(`Invalid recurrence date: ${value}`)
  return parsed
}

export function addCalendarDays(value: string, days: number): string {
  return formatCalendarDate(dateFromDayNumber(dayNumber(date(value)) + days))
}

export function localDay(instant: Date, zone: string): string {
  return formatCalendarDate(localDate(instant.getTime(), zone))
}

/** First matching date on/after from; month-end clamps without drifting the following month. */
export function nextOccurrence(rule: RecurrenceRule, from: string): string | undefined {
  const lower = from < rule.startDate ? rule.startDate : from
  const anchor = date(rule.startDate)
  const first = date(lower)
  let result: string
  if (rule.frequency === 'day') {
    const steps = Math.ceil((dayNumber(first) - dayNumber(anchor)) / rule.interval)
    result = addCalendarDays(rule.startDate, steps * rule.interval)
  } else if (rule.frequency === 'week') {
    const monday = dayNumber(anchor) - (weekdayOf(anchor) + 6) % 7
    const week = Math.floor((dayNumber(first) - monday) / 7)
    let activeWeek = week + (rule.interval - week % rule.interval) % rule.interval
    const weekdays = rule.weekdays ?? [weekdayOf(anchor)]
    const offsets = weekdays.map((day) => (day + 6) % 7).sort((a, b) => a - b)
    // At most two active weeks: the first can be partially before the lower bound.
    for (;;) {
      const candidate = offsets.map((offset) => monday + activeWeek * 7 + offset).find((day) => day >= dayNumber(first))
      if (candidate !== undefined) {
        result = formatCalendarDate(dateFromDayNumber(candidate))
        break
      }
      activeWeek += rule.interval
    }
  } else {
    const anchorMonth = anchor.year * 12 + anchor.month - 1
    const firstMonth = first.year * 12 + first.month - 1
    let step = Math.ceil((firstMonth - anchorMonth) / rule.interval)
    for (;;) {
      const monthIndex = anchorMonth + step * rule.interval
      const year = Math.floor(monthIndex / 12)
      const month = monthIndex % 12 + 1
      const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate()
      result = formatCalendarDate({ year, month, day: Math.min(rule.dayOfMonth ?? anchor.day, lastDay) })
      if (result >= lower) break
      step += 1
    }
  }
  if (result.length !== 10 || (rule.endDate != null && result > rule.endDate)) return undefined
  return result
}

/** Upcoming dates in the horizon; retain the next one even when the interval exceeds the horizon. */
export function occurrenceDates(rule: RecurrenceRule, from: string, through: string): string[] {
  const dates: string[] = []
  let next = nextOccurrence(rule, from)
  while (next !== undefined && next <= through) {
    dates.push(next)
    next = nextOccurrence(rule, addCalendarDays(next, 1))
  }
  if (dates.length === 0 && next !== undefined) dates.push(next)
  return dates
}

/** Move an instant by calendar dates while keeping its local clock, including across DST. */
export function shiftRecurrenceInstant(instant: string, anchor: string, occurrence: string, zone: string): Date {
  const ms = new Date(instant).getTime()
  const parts = localParts(ms, zone)
  const target = dateFromDayNumber(dayNumber(parts) + dayNumber(date(occurrence)) - dayNumber(date(anchor)))
  return new Date(zonedToUtc(target, parts.hour * 60 + parts.minute + parts.second / 60, zone) + ms % 1000)
}

export function occurrenceFields(template: RecurringTaskTemplate, rule: RecurrenceRule, occurrence: string) {
  const { anchorDate, dueAt, startAt, pinnedStart, ...fields } = template
  const day = date(occurrence)
  const shift = (instant: string) => shiftRecurrenceInstant(instant, anchorDate, occurrence, rule.timeZone)
  return {
    ...fields,
    source: template.source ?? null,
    deadlineType: fields.someday ? 'none' as const : fields.deadlineType,
    startAt: startAt === null ? new Date(zonedToUtc(day, 0, rule.timeZone)) : shift(startAt),
    dueAt: fields.someday ? null : dueAt === null ? new Date(zonedToUtc(dateFromDayNumber(dayNumber(day) + 1), 0, rule.timeZone) - 1) : shift(dueAt),
    pinnedStart: fields.someday || pinnedStart === null ? null : shift(pinnedStart),
  }
}
