import { describe, expect, it } from 'vitest'
import {
  dateFromDayNumber,
  dayNumber,
  localParts,
  parseClock,
  tzOffsetMs,
  weekdayOf,
  zonedToUtc,
} from '../src/index.js'

const LA = 'America/Los_Angeles'
const ms = (iso: string): number => Date.parse(iso)

describe('zonedToUtc', () => {
  it('converts wall time before and after the US fall-back on 2026-11-01', () => {
    expect(zonedToUtc({ year: 2026, month: 10, day: 30 }, 9 * 60, LA)).toBe(ms('2026-10-30T16:00:00Z'))
    expect(zonedToUtc({ year: 2026, month: 11, day: 2 }, 9 * 60, LA)).toBe(ms('2026-11-02T17:00:00Z'))
  })

  it('resolves an ambiguous fall-back time to its first occurrence', () => {
    // 01:30 happens twice on 2026-11-01 in LA; the first is PDT (UTC-7).
    expect(zonedToUtc({ year: 2026, month: 11, day: 1 }, 90, LA)).toBe(ms('2026-11-01T08:30:00Z'))
  })

  it('shifts a nonexistent spring-forward time past the gap', () => {
    // 02:30 does not exist on 2026-03-08 in LA; it becomes 03:30 PDT.
    expect(zonedToUtc({ year: 2026, month: 3, day: 8 }, 150, LA)).toBe(ms('2026-03-08T10:30:00Z'))
  })

  it('handles zones east of UTC across a date boundary', () => {
    expect(zonedToUtc({ year: 2026, month: 1, day: 1 }, 0, 'Asia/Tokyo')).toBe(ms('2025-12-31T15:00:00Z'))
  })

  it('accepts 24:00 as the end of the day', () => {
    expect(zonedToUtc({ year: 2026, month: 11, day: 9 }, parseClock('24:00'), 'UTC')).toBe(ms('2026-11-10T00:00:00Z'))
  })
})

describe('localParts and offsets', () => {
  it('reads wall-clock parts in the zone', () => {
    expect(localParts(ms('2026-11-09T17:00:00Z'), LA)).toEqual({
      year: 2026,
      month: 11,
      day: 9,
      hour: 9,
      minute: 0,
      second: 0,
    })
  })

  it('reports midnight as hour 0', () => {
    expect(localParts(ms('2026-11-10T08:00:00Z'), LA).hour).toBe(0)
  })

  it('returns negative offsets west of UTC and positive east', () => {
    expect(tzOffsetMs(ms('2026-11-09T17:00:00Z'), LA)).toBe(-8 * 3_600_000)
    expect(tzOffsetMs(ms('2026-07-01T00:00:00Z'), 'Europe/Berlin')).toBe(2 * 3_600_000)
  })

  it('rejects unknown zones', () => {
    expect(() => localParts(0, 'Mars/Olympus')).toThrow(RangeError)
  })
})

describe('day arithmetic', () => {
  it('round-trips dates through day numbers', () => {
    const date = { year: 2026, month: 2, day: 28 }
    expect(dateFromDayNumber(dayNumber(date))).toEqual(date)
    expect(dateFromDayNumber(dayNumber(date) + 1)).toEqual({ year: 2026, month: 3, day: 1 })
  })

  it('knows weekdays', () => {
    expect(weekdayOf({ year: 2026, month: 11, day: 8 })).toBe(0) // Sunday
    expect(weekdayOf({ year: 2026, month: 11, day: 9 })).toBe(1) // Monday
  })
})

describe('parseClock', () => {
  it('parses HH:MM', () => {
    expect(parseClock('09:00')).toBe(540)
    expect(parseClock('9:05')).toBe(545)
    expect(parseClock('23:59')).toBe(1439)
  })

  it('rejects malformed or out-of-range times', () => {
    for (const bad of ['9', '25:00', '24:01', '12:60', 'noon', '']) {
      expect(() => parseClock(bad), bad).toThrow(RangeError)
    }
  })
})
