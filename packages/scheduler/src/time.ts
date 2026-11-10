export const MINUTE = 60_000
export const HOUR = 60 * MINUTE
export const DAY = 24 * HOUR

/** A calendar date with no time zone; `month` is 1–12. */
export interface LocalDate {
  year: number
  month: number
  day: number
}

export interface LocalParts extends LocalDate {
  hour: number
  minute: number
  second: number
}

const formatters = new Map<string, Intl.DateTimeFormat>()

function formatter(timeZone: string): Intl.DateTimeFormat {
  let f = formatters.get(timeZone)
  if (f === undefined) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
      second: 'numeric',
    })
    formatters.set(timeZone, f)
  }
  return f
}

/** Wall-clock parts of the instant `ms` in `timeZone`. Throws RangeError for an unknown zone. */
export function localParts(ms: number, timeZone: string): LocalParts {
  const out: LocalParts = { year: 0, month: 0, day: 0, hour: 0, minute: 0, second: 0 }
  for (const part of formatter(timeZone).formatToParts(new Date(ms))) {
    switch (part.type) {
      case 'year':
        out.year = Number(part.value)
        break
      case 'month':
        out.month = Number(part.value)
        break
      case 'day':
        out.day = Number(part.value)
        break
      case 'hour':
        // Some engines print midnight as "24" even with hourCycle h23.
        out.hour = Number(part.value) % 24
        break
      case 'minute':
        out.minute = Number(part.value)
        break
      case 'second':
        out.second = Number(part.value)
        break
      default:
        break
    }
  }
  return out
}

export function localDate(ms: number, timeZone: string): LocalDate {
  const { year, month, day } = localParts(ms, timeZone)
  return { year, month, day }
}

/** Offset of `timeZone` from UTC at instant `ms`, in milliseconds (positive east of UTC). */
export function tzOffsetMs(ms: number, timeZone: string): number {
  const p = localParts(ms, timeZone)
  const wall = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second)
  return wall - Math.floor(ms / 1000) * 1000
}

/**
 * The instant at which the wall clock in `timeZone` reads `date` + `minutesOfDay`.
 *
 * Ambiguous wall times (clocks fall back) resolve to the earlier instant. Nonexistent wall
 * times (clocks spring forward) resolve to the instant the pre-gap offset would give, i.e.
 * shifted forward past the gap.
 */
export function zonedToUtc(date: LocalDate, minutesOfDay: number, timeZone: string): number {
  const wall = Date.UTC(date.year, date.month - 1, date.day) + minutesOfDay * MINUTE
  const offset1 = tzOffsetMs(wall, timeZone)
  const candidate1 = wall - offset1
  if (tzOffsetMs(candidate1, timeZone) === offset1) return candidate1
  const offset2 = tzOffsetMs(candidate1, timeZone)
  const candidate2 = wall - offset2
  if (tzOffsetMs(candidate2, timeZone) === offset2) return candidate2
  return candidate1
}

/** Days since 1970-01-01 for a local date, so callers can step through consecutive days. */
export function dayNumber(date: LocalDate): number {
  return Date.UTC(date.year, date.month - 1, date.day) / DAY
}

export function dateFromDayNumber(day: number): LocalDate {
  const d = new Date(day * DAY)
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() }
}

/** "YYYY-MM-DD". */
export function isoDate(date: LocalDate): string {
  const pad = (n: number, width: number): string => String(n).padStart(width, '0')
  return `${pad(date.year, 4)}-${pad(date.month, 2)}-${pad(date.day, 2)}`
}

/** 0 = Sunday … 6 = Saturday. */
export function weekdayOf(date: LocalDate): number {
  return new Date(Date.UTC(date.year, date.month - 1, date.day)).getUTCDay()
}

/** Parses "HH:MM" into minutes after midnight. "24:00" is accepted as end of day. */
export function parseClock(clock: string): number {
  const match = /^(\d{1,2}):(\d{2})$/.exec(clock)
  if (match === null) throw new RangeError(`Invalid clock time: ${clock}`)
  const hours = Number(match[1])
  const minutes = Number(match[2])
  if (hours > 24 || minutes > 59 || (hours === 24 && minutes > 0)) {
    throw new RangeError(`Invalid clock time: ${clock}`)
  }
  return hours * 60 + minutes
}
