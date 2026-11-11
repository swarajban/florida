import { randomUUID } from 'node:crypto'
import { and, eq, ne } from 'drizzle-orm'
import { z } from 'zod'
import type { Db } from './db/client.js'
import { calendars, events } from './db/schema.js'
import type { CalendarRow, EventRow } from './db/schema.js'
import { GoogleApiError, mapEvent } from './google/client.js'
import type { GoogleEvent, GoogleEventTimeWrite, GoogleEventWrite } from './google/client.js'
import type { CalendarSyncService } from './google/sync.js'
import { badRequest, forbidden, isoInstant, notFound, timeZone } from './validation.js'

export const responseStatus = z.enum(['accepted', 'declined', 'tentative', 'needsAction'])

/**
 * Full event body as accepted by `PUT /api/events/:id`. All-day events carry UTC midnight instants:
 * `startAt` is the first day and `endAt` the day after the last one, as `mapEvent` stores them.
 */
export const eventBody = z
  .object({
    calendarId: z.string().min(1),
    summary: z.string(),
    location: z.string().nullish(),
    description: z.string().nullish(),
    startAt: isoInstant,
    endAt: isoInstant,
    allDay: z.boolean(),
    /** The user's own RSVP. `null` leaves it alone; it is ignored when creating. */
    responseStatus: responseStatus.nullish(),
    /** Creation only. Google owns the series; stored rows are individual instances. */
    recurrence: z.object({
      frequency: z.enum(['daily', 'weekly', 'monthly', 'yearly']),
      interval: z.number().int().min(1).max(99),
      timeZone,
      count: z.number().int().min(1).max(999).nullish(),
    }).nullish(),
  })
  .refine((b) => new Date(b.endAt) > new Date(b.startAt), { message: 'endAt must be after startAt', path: ['endAt'] })
  .refine((b) => !b.allDay || (isUtcMidnight(b.startAt) && isUtcMidnight(b.endAt)), {
    message: 'startAt and endAt of an all-day event must be UTC midnight',
    path: ['startAt'],
  })
export type EventBody = z.infer<typeof eventBody>

const WRITABLE_ROLES: readonly string[] = ['owner', 'writer']
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/**
 * Creates or edits a Google Calendar event and stores Google's copy under `id`, so the result is
 * exactly what a later sync would write. An unknown id creates the event in `body.calendarId`; a
 * live row is patched on Google with only the fields that changed. A tombstone is 404: the event is
 * gone on Google, and the client learns that from `GET /api/events/:id`. When Google turns out to
 * have deleted the event since the last sync, the row is tombstoned and returned as such, so the
 * caller can reschedule before answering 404.
 */
export async function upsertEvent(
  db: Db,
  sync: CalendarSyncService,
  id: string,
  body: EventBody,
  now: Date = new Date(),
): Promise<EventRow> {
  const [current] = await db.select().from(events).where(eq(events.id, id)).limit(1)
  if (current === undefined) return createEvent(db, sync, id, body, now)
  if (current.deletedAt !== null) throw notFound(`event ${id}`)
  // A queued create can be edited while its first push is in flight. Once it exists, keep the
  // recurrence creation-only and apply ordinary field changes to its first occurrence.
  if (body.recurrence != null && current.recurringEventId !== googleEventId(id)) {
    throw badRequest('repeat can only be set when creating a new event')
  }
  return updateEvent(db, sync, current, body, now)
}

async function createEvent(db: Db, sync: CalendarSyncService, id: string, body: EventBody, now: Date): Promise<EventRow> {
  const calendar = await writableCalendar(db, body.calendarId)
  const googleId = googleEventId(id)
  const repeat = body.recurrence
  if (repeat != null && googleId === undefined) throw badRequest('recurring events require a UUID id')
  const zone = repeat != null && !body.allDay ? { timeZone: repeat.timeZone } : {}
  let created: GoogleEvent
  try {
    created = await sync.createEvent(calendar, {
      ...(googleId === undefined ? {} : { id: googleId }),
      summary: body.summary,
      ...(body.location == null ? {} : { location: body.location }),
      ...(body.description == null ? {} : { description: body.description }),
      start: { ...googleTime(new Date(body.startAt), body.allDay), ...zone },
      end: { ...googleTime(new Date(body.endAt), body.allDay), ...zone },
      ...(repeat == null ? {} : {
        recurrence: [`RRULE:FREQ=${repeat.frequency.toUpperCase()};INTERVAL=${repeat.interval}${repeat.count == null ? '' : `;COUNT=${repeat.count}`}`],
      }),
    })
  } catch (err) {
    // 409 under our own id: an earlier attempt reached Google but its reply (or our row) was lost.
    // The event exists, so store Google's copy as that attempt would have.
    if (googleId === undefined || !(err instanceof GoogleApiError && err.status === 409)) throw err
    created = await sync.getEvent(calendar, googleId)
  }
  // Never store a series master as an occurrence: that would duplicate the first event and
  // make editing/deleting it affect the entire series. Fetch Google's expansion before storing.
  const instances = repeat == null ? [created] : await sync.eventInstances(
    calendar, created.id, body.startAt,
    new Date(Math.max(now.getTime(), new Date(body.startAt).getTime()) + 365 * 86_400_000).toISOString(),
  )
  // The instances endpoint does not promise an order, including across page boundaries.
  const occurrences = instances.map((instance) => mapEvent(calendar.id, instance, now))
    .sort((a, b) => (a.startAt?.getTime() ?? Infinity) - (b.startAt?.getTime() ?? Infinity))
  const row = occurrences[0]
  if (row === undefined) throw new Error('Google returned no occurrences for the new event')
  return db.transaction(async (tx) => {
    // A sync that ran between Google's reply and this write already holds the event under a random
    // id. The client's id wins, so its optimistic row and the server's row are the same record.
    await tx
      .delete(events)
      .where(and(eq(events.calendarId, calendar.id), eq(events.googleId, row.googleId), ne(events.id, id)))
    const [stored] = await tx
      .insert(events)
      .values({ id, ...row })
      .onConflictDoUpdate({ target: events.id, set: row })
      .returning()
    if (stored === undefined) throw new Error(`insert of event ${id} returned no row`)
    for (const occurrence of occurrences.slice(1)) {
      await tx.insert(events).values({ id: randomUUID(), ...occurrence })
        .onConflictDoUpdate({ target: [events.calendarId, events.googleId], set: occurrence })
    }
    return stored
  })
}

async function updateEvent(
  db: Db,
  sync: CalendarSyncService,
  current: EventRow,
  body: EventBody,
  now: Date,
): Promise<EventRow> {
  if (body.calendarId !== current.calendarId) throw badRequest('moving an event to another calendar is not supported')
  const calendar = await writableCalendar(db, current.calendarId)
  const patch = changedFields(current, body)
  const rsvp = body.responseStatus ?? null
  let updated: GoogleEvent | undefined
  try {
    if (rsvp !== null && rsvp !== current.responseStatus) {
      // Google replaces the attendee array wholesale, so an RSVP re-sends every attendee. They come
      // from Google's current copy, not ours, which may be behind: a stale list would drop guests.
      const live = await sync.getEvent(calendar, current.googleId)
      const attendees = live.attendees ?? []
      const self = attendees.find((a) => a.self === true)
      if (self === undefined) throw badRequest('cannot respond to an event this account is not a guest of')
      // Already answered that way from another device: nothing to send, but Google's copy brings
      // the row (and the client that is behind) up to date.
      if (self.responseStatus === rsvp) updated = live
      else patch.attendees = attendees.map((a) => (a === self ? { ...a, responseStatus: rsvp } : a))
    }
    if (Object.keys(patch).length > 0) updated = await sync.updateEvent(calendar, current.googleId, patch)
  } catch (err) {
    // Google no longer has the event (deleted since the last sync), so the edit cannot apply. The
    // tombstone is what the client's refetch needs to drop its optimistic copy.
    if (!isGone(err)) throw err
    return tombstoneEvent(db, current.id, now)
  }
  if (updated === undefined) return current
  const [stored] = await db
    .update(events)
    .set(mapEvent(calendar.id, updated, now))
    .where(eq(events.id, current.id))
    .returning()
  if (stored === undefined) throw notFound(`event ${current.id}`)
  return stored
}

/**
 * Deletes the event on Google (an event Google already removed counts as deleted) and tombstones
 * the row. A row that is already a tombstone is left alone. Throws 404 for an unknown id.
 */
export async function softDeleteEvent(db: Db, sync: CalendarSyncService, id: string, now: Date = new Date()): Promise<void> {
  const [current] = await db.select().from(events).where(eq(events.id, id)).limit(1)
  if (current === undefined) throw notFound(`event ${id}`)
  if (current.deletedAt !== null) return
  const calendar = await writableCalendar(db, current.calendarId)
  await sync.deleteEvent(calendar, current.googleId)
  await tombstoneEvent(db, id, now)
}

async function tombstoneEvent(db: Db, id: string, now: Date): Promise<EventRow> {
  const [row] = await db.update(events).set({ deletedAt: now, updatedAt: now }).where(eq(events.id, id)).returning()
  if (row === undefined) throw notFound(`event ${id}`)
  return row
}

/** A 404 or 410 from a single-event method: Google no longer has the event. */
function isGone(err: unknown): boolean {
  return err instanceof GoogleApiError && (err.status === 404 || err.status === 410)
}

/** The calendar if it is synced and the account may write to it: 400 for an unknown id, 403 otherwise. */
async function writableCalendar(db: Db, calendarId: string): Promise<CalendarRow> {
  const [calendar] = await db.select().from(calendars).where(eq(calendars.id, calendarId)).limit(1)
  if (calendar === undefined) throw badRequest(`unknown calendarId ${calendarId}`)
  if (!calendar.selected) throw forbidden(`calendar ${calendarId} is not synced`)
  if (!WRITABLE_ROLES.includes(calendar.accessRole)) {
    throw forbidden(`calendar ${calendarId} is read-only (access role ${calendar.accessRole})`)
  }
  return calendar
}

/** What differs between the stored row and the body, in Google's shape. Start and end travel together. */
function changedFields(current: EventRow, body: EventBody): GoogleEventWrite {
  const patch: GoogleEventWrite = {}
  if (body.summary !== (current.summary ?? '')) patch.summary = body.summary
  const location = body.location ?? null
  if (location !== current.location) patch.location = location
  const description = body.description ?? null
  if (description !== current.description) patch.description = description
  const startAt = new Date(body.startAt)
  const endAt = new Date(body.endAt)
  const switched = body.allDay !== current.allDay
  if (switched || !sameTime(current.startAt, startAt, body.allDay) || !sameTime(current.endAt, endAt, body.allDay)) {
    patch.start = googleTime(startAt, body.allDay, switched)
    patch.end = googleTime(endAt, body.allDay, switched)
  }
  return patch
}

function sameTime(stored: Date | null, next: Date, allDay: boolean): boolean {
  if (stored === null) return false
  return allDay ? utcDate(stored) === utcDate(next) : stored.getTime() === next.getTime()
}

/**
 * `date` (the UTC calendar date) for all-day events, `dateTime` otherwise. When an event switches
 * between the two, the other key is sent as `null`: patches merge nested objects and Google rejects
 * an event holding both.
 */
function googleTime(at: Date, allDay: boolean, clearOther = false): GoogleEventTimeWrite {
  if (allDay) return clearOther ? { date: utcDate(at), dateTime: null } : { date: utcDate(at) }
  return clearOther ? { dateTime: at.toISOString(), date: null } : { dateTime: at.toISOString() }
}

function utcDate(at: Date): string {
  return at.toISOString().slice(0, 10)
}

function isUtcMidnight(iso: string): boolean {
  return new Date(iso).getTime() % 86_400_000 === 0
}

/**
 * The id to create the event under on Google when the client's id allows it. The apps use UUIDs,
 * whose 32 hex digits are valid base32hex (Google wants 5–1024 characters of [0-9a-v]); choosing
 * the id makes a retried create answer 409 instead of making a second event. Other ids leave the
 * choice to Google.
 */
function googleEventId(id: string): string | undefined {
  return UUID_RE.test(id) ? id.toLowerCase().replace(/-/g, '') : undefined
}
