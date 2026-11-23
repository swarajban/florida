import { type Span, subtractSpans } from './intervals.js'
import { MINUTE, dateFromDayNumber, dayNumber, isoDate, localDate, parseClock, weekdayOf, zonedToUtc } from './time.js'
import type { CatchUpBlock, SchedulerInput } from './types.js'

export function scheduleCatchUp(
  { settings, queue, previous }: NonNullable<SchedulerInput['catchUp']>,
  timeZone: string, now: number, horizonEnd: number, taken: Span[],
): CatchUpBlock[] {
  if (!settings.enabled) return []
  const prior = new Map(previous?.map((block) => [block.id, block]))
  const total = queue.reduce((sum, item) => sum + item.estMinutes, 0)
  const blocks: CatchUpBlock[] = []
  const first = dayNumber(localDate(now, timeZone))
  const last = dayNumber(localDate(horizonEnd - 1, timeZone))
  for (let day = first; day <= last; day++) {
    const date = dateFromDayNumber(day)
    const id = isoDate(date)
    const window = settings.windows.find((window) => window.days.includes(weekdayOf(date)))
    if (window === undefined) continue
    const earlier = prior.get(id)
    if (earlier !== undefined && Date.parse(earlier.endAt) <= now) {
      blocks.push(earlier)
      continue
    }
    if (total === 0) continue
    const minutes = Math.max(10, Math.min(window.minutes ?? settings.minutes, total))
    let remaining = minutes
    const items = queue.filter((item) => {
      if (item.estMinutes > remaining) return false
      remaining -= item.estMinutes
      return true
    })
    if (items.length === 0) continue
    const windowStart = zonedToUtc(date, parseClock(window.start), timeZone)
    const end = Math.min(zonedToUtc(date, parseClock(window.end), timeZone), horizonEnd)
    const oldStart = earlier === undefined ? Number.NaN : Date.parse(earlier.startAt)
    const oldEnd = oldStart + minutes * MINUTE
    const active = oldStart <= now && now < oldEnd && oldStart >= windowStart && oldEnd <= end
      && !taken.some((span) => span.start < oldEnd && span.end > oldStart)
    const start = Math.max(windowStart, Math.ceil(now / MINUTE) * MINUTE)
    const free = active ? oldStart : subtractSpans({ start, end }, taken)
      .find((span) => span.end - span.start >= minutes * MINUTE)?.start
    if (free === undefined) continue
    blocks.push({ id, startAt: new Date(free).toISOString(), endAt: new Date(free + minutes * MINUTE).toISOString(), items })
  }
  return blocks
}
