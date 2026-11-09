import type { LocalDate } from '@florida/scheduler'
import { HTTPException } from 'hono/http-exception'
import { z } from 'zod'

/** ISO 8601 instant with an explicit offset or `Z`. */
export const isoInstant = z.iso.datetime({ offset: true })
/** Wall-clock "HH:MM". */
export const clock = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'expected HH:MM')
/** IANA time zone name accepted by this runtime's `Intl`. */
export const timeZone = z.string().refine(isTimeZone, 'unknown IANA time zone')
/** Calendar date "YYYY-MM-DD" that exists (rejects 2026-02-30). */
export const calendarDate = z
  .string()
  .refine((s) => parseCalendarDate(s) !== undefined, 'expected a valid YYYY-MM-DD date')

export function isTimeZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz })
    return true
  } catch {
    return false
  }
}

export function parseCalendarDate(s: string): LocalDate | undefined {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s)
  if (match === null) return undefined
  const date = { year: Number(match[1]), month: Number(match[2]), day: Number(match[3]) }
  const probe = new Date(Date.UTC(date.year, date.month - 1, date.day))
  const exists =
    probe.getUTCFullYear() === date.year && probe.getUTCMonth() === date.month - 1 && probe.getUTCDate() === date.day
  return exists ? date : undefined
}

export function formatCalendarDate(date: LocalDate): string {
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${date.year}-${pad(date.month)}-${pad(date.day)}`
}

export function toDate(iso: string | null | undefined): Date | null {
  return iso == null ? null : new Date(iso)
}

export function badRequest(message: string): HTTPException {
  return new HTTPException(400, { message })
}

export function forbidden(message: string): HTTPException {
  return new HTTPException(403, { message })
}

export function notFound(what: string): HTTPException {
  return new HTTPException(404, { message: `${what} not found` })
}
