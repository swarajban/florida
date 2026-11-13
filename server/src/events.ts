import { randomUUID } from 'node:crypto'
import { dayNumber, localDate, localParts, zonedToUtc } from '@florida/scheduler'
import { and, eq, inArray, isNull, ne } from 'drizzle-orm'
import { z } from 'zod'
import type { Db } from './db/client.js'
import { calendars, events } from './db/schema.js'
import type { CalendarRow, EventRow } from './db/schema.js'
import { GoogleApiError } from './google/client.js'
import { automaticDayFields, judgedGoogleEvent, learnAccountProfiles, refreshAllDayJudgments } from './google/all-day-state.js'
import type { GoogleEvent, GoogleEventTimeWrite, GoogleEventWrite } from './google/client.js'
import { FULL_SYNC_FUTURE_DAYS, FULL_SYNC_PAST_DAYS } from './google/sync.js'
import type { CalendarSyncService } from './google/sync.js'
import { badRequest, forbidden, isoInstant, notFound, timeZone } from './validation.js'

export const responseStatus = z.enum(['accepted', 'declined', 'tentative', 'needsAction'])

const DAY = 86_400_000

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
    blocksDay: z.boolean().nullable().optional(),
    /** The user's own RSVP. `null` leaves it alone; it is ignored when creating. */
    responseStatus: responseStatus.nullish(),
    /** Creation only. Google owns the series; stored rows are individual instances. */
    recurrence: z.object({
      frequency: z.enum(['daily', 'weekly', 'monthly', 'yearly']),
      interval: z.number().int().min(1).max(99),
      timeZone,
      count: z.number().int().min(1).max(999).nullish(),
    }).nullish(),
    /**
     * `'series'` on an instance of a recurring event gives the whole series the time of day and
     * the length of `startAt`/`endAt`; every instance keeps its day. Absent, or on an event that
     * does not repeat, only this event changes.
     */
    scope: z.enum(['instance', 'series']).nullish(),
  })
  .refine((b) => new Date(b.endAt) > new Date(b.startAt), { message: 'endAt must be after startAt', path: ['endAt'] })
  .refine((b) => !b.allDay || (isUtcMidnight(b.startAt) && isUtcMidnight(b.endAt)), {
    message: 'startAt and endAt of an all-day event must be UTC midnight',
    path: ['startAt'],
  })
export type EventBody = z.infer<typeof eventBody>

export const eventBlockingPatch = z.object({ blocksDay: z.boolean().nullable() }).strict()

export async function setEventBlocksDay(db: Db, id: string, blocksDay: boolean | null, now: Date = new Date()): Promise<EventRow> {
  return db.transaction(async (tx) => {
    const [current] = await tx.select().from(events).where(eq(events.id, id)).for('update')
    if (current === undefined || current.deletedAt !== null) throw notFound(`event ${id}`)
    if (!current.allDay) throw badRequest('Blocks my day is only available for all-day events')
    const [calendar] = await tx.select().from(calendars).where(eq(calendars.id, current.calendarId))
    if (calendar === undefined) throw notFound(`calendar ${current.calendarId}`)
    const { profiles } = await learnAccountProfiles(tx, [], now)
    const [event] = await tx.update(events).set({ blocksDay, ...automaticDayFields(current, calendar, profiles), updatedAt: now }).where(eq(events.id, id)).returning()
    if (event === undefined) throw notFound(`event ${id}`)
    return event
  })
}

const WRITABLE_ROLES: readonly string[] = ['owner', 'writer']
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/**
 * Creates or edits a Google Calendar event and stores Google's copy under `id`, so the result is
 * exactly what a later sync would write. An unknown id creates the event in `body.calendarId`; a
 * live row is patched on Google with only the fields that changed. A tombstone is 404: the event is
 * gone on Google, and the client learns that from `GET /api/events/:id`. When Google turns out to
 * have deleted the event since the last sync, the row is tombstoned and returned as such, so the
 * caller can reschedule before answering 404. With `scope: 'series'` the other rows of the series
 * change too (`moveSeries`).
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
  const { profiles, learned } = await learnAccountProfiles(db, instances, now)
  if (learned) await refreshAllDayJudgments(db, now)
  const occurrences = instances.map((instance) => judgedGoogleEvent(calendar, instance, profiles, now))
    .sort((a, b) => (a.startAt?.getTime() ?? Infinity) - (b.startAt?.getTime() ?? Infinity))
  const row = occurrences[0]
  if (row === undefined) throw new Error('Google returned no occurrences for the new event')
  return db.transaction(async (tx) => {
    // A sync that ran between Google's reply and this write already holds the event under a random
    // id. The client's id wins, so its optimistic row and the server's row are the same record.
    const [raced] = await tx.select({ blocksDay: events.blocksDay }).from(events)
      .where(and(eq(events.calendarId, calendar.id), eq(events.googleId, row.googleId))).for('update')
    const fields = { ...row, blocksDay: body.blocksDay === undefined ? raced?.blocksDay ?? null : body.blocksDay }
    await tx
      .delete(events)
      .where(and(eq(events.calendarId, calendar.id), eq(events.googleId, row.googleId), ne(events.id, id)))
    const [stored] = await tx
      .insert(events)
      .values({ id, ...fields })
      .onConflictDoUpdate({ target: events.id, set: fields })
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
  const seriesId = body.scope === 'series' ? current.recurringEventId : null
  if (body.calendarId !== current.calendarId) throw badRequest('moving an event to another calendar is not supported')
  if (body.blocksDay !== undefined && current.allDay && seriesId === null && Object.keys(changedFields(current, body)).length === 0
    && (body.responseStatus == null || body.responseStatus === current.responseStatus)) {
    return setEventBlocksDay(db, current.id, body.blocksDay, now)
  }
  let moved = false
  try {
    const calendar = await writableCalendar(db, current.calendarId)
    // The times of a series move go to the series; this instance is patched for what else changed.
    const stored = await updateInstance(db, sync, calendar, current, body, now, seriesId === null)
    if (seriesId === null || stored.deletedAt !== null) return stored
    const result = await moveSeries(db, sync, calendar, stored, seriesId, body, now)
    moved = result.deletedAt === null
    return result
  } finally {
    // The apps move every instance of a series before they push. When the move did not go through,
    // whatever the reason, the rows are stamped so the next `/api/sync` hands them the stored times.
    if (seriesId !== null && !moved) {
      await db.update(events).set({ updatedAt: now }).where(liveSeries(current.calendarId, seriesId))
    }
  }
}

/**
 * Patches one event on Google with what changed and stores Google's copy. Without `withTimes` a
 * changed start or end is left out. When Google no longer has the event, the row is tombstoned.
 */
async function updateInstance(
  db: Db,
  sync: CalendarSyncService,
  calendar: CalendarRow,
  current: EventRow,
  body: EventBody,
  now: Date,
  withTimes: boolean,
): Promise<EventRow> {
  const patch = changedFields(current, body)
  if (!withTimes) {
    delete patch.start
    delete patch.end
  }
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
  if (updated === undefined && (body.blocksDay === undefined || body.blocksDay === current.blocksDay)) return current
  const { profiles, learned } = await learnAccountProfiles(db, updated === undefined ? [] : [updated], now)
  if (learned) await refreshAllDayJudgments(db, now)
  const [row] = await db
    .update(events)
    .set({
      ...(updated === undefined ? { updatedAt: now, ...automaticDayFields(current, calendar, profiles) } : judgedGoogleEvent(calendar, updated, profiles, now)),
      ...(body.blocksDay === undefined ? {} : { blocksDay: body.blocksDay }),
    })
    .where(eq(events.id, current.id))
    .returning()
  if (row === undefined) throw notFound(`event ${current.id}`)
  return row
}

/**
 * Moves a recurring event as a whole: its master takes the time of day of `body.startAt`, read in
 * the zone the series repeats in, and the length of the body, and keeps its date. The target is
 * absolute, so a retry after a lost reply patches nothing. The rows of the series are then replaced
 * by Google's instances (`storeSeries`). A series Google no longer has tombstones the row.
 *
 * Two moves are refused before Google is touched:
 * - To another day, in the series' zone, than the instance is on. The master keeps its date, so
 *   every instance would land a day from where it was dropped.
 * - Of a series in which this instance or an upcoming one was moved on its own. Google is reported
 *   to drop such instances when the master's time changes, and it mails the guests. That report is
 *   not verified; until it is, the series is left to Google Calendar.
 */
async function moveSeries(
  db: Db,
  sync: CalendarSyncService,
  calendar: CalendarRow,
  current: EventRow,
  seriesId: string,
  body: EventBody,
  now: Date,
): Promise<EventRow> {
  if (body.allDay) throw badRequest('an all-day series cannot be moved as a whole')
  try {
    const master = await sync.getEvent(calendar, seriesId)
    const zone = master.start?.timeZone
    if (master.start?.dateTime === undefined || master.end?.dateTime === undefined || zone === undefined) {
      throw badRequest('only a timed recurring event can be moved as a whole')
    }
    const from = new Date(master.start.dateTime).getTime()
    const length = new Date(master.end.dateTime).getTime() - from
    const target = new Date(body.startAt).getTime()
    const targetLength = new Date(body.endAt).getTime() - target
    if (current.startAt === null || dayNumber(localDate(target, zone)) !== dayNumber(localDate(current.startAt.getTime(), zone))) {
      throw badRequest(`a recurring event can only be moved as a whole within its day in ${zone}`)
    }
    const time = localParts(target, zone)
    const start = zonedToUtc(localDate(from, zone), time.hour * 60 + time.minute + time.second / 60, zone)
    if (start !== from || targetLength !== length) {
      const { instances } = await readSeries(db, sync, calendar, seriesId, now)
      const upcoming = (e: GoogleEvent) => e.start?.dateTime !== undefined && new Date(e.start.dateTime) >= now
      if (instances.some((e) => (e.id === current.googleId || upcoming(e)) && movedAlone(e, length))) {
        throw badRequest('this series has an event that was moved on its own; move the series in Google Calendar')
      }
      await sync.updateEvent(calendar, seriesId, {
        start: { dateTime: new Date(start).toISOString(), timeZone: zone },
        end: { dateTime: new Date(start + targetLength).toISOString(), timeZone: master.end.timeZone ?? zone },
      })
    }
    return await storeSeries(db, sync, calendar, current, seriesId, target, now)
  } catch (err) {
    if (!isGone(err)) throw err
    return tombstoneEvent(db, current.id, now)
  }
}

/**
 * Whether an instance of a timed series was given a start or a length of its own: Google reports
 * where the series put it as `originalStartTime`, and `seriesLength` is the master's.
 */
function movedAlone(instance: GoogleEvent, seriesLength: number): boolean {
  if (instance.start?.dateTime === undefined || instance.end?.dateTime === undefined) return false
  const start = new Date(instance.start.dateTime).getTime()
  const original = instance.originalStartTime?.dateTime
  if (original !== undefined && new Date(original).getTime() !== start) return true
  return new Date(instance.end.dateTime).getTime() - start !== seriesLength
}

/**
 * The live rows of one recurring event and Google's instances of it. The instances are listed over
 * the usual sync window, widened to every row we hold: a row outside it would otherwise look gone.
 */
async function readSeries(db: Db, sync: CalendarSyncService, calendar: CalendarRow, seriesId: string, now: Date) {
  const live = await db
    .select({ id: events.id, googleId: events.googleId, startAt: events.startAt, endAt: events.endAt })
    .from(events)
    .where(liveSeries(calendar.id, seriesId))
  const starts = live.flatMap((e) => (e.startAt === null ? [] : [e.startAt.getTime()]))
  const ends = live.flatMap((e) => (e.endAt === null ? [] : [e.endAt.getTime()]))
  const instances = await sync.eventInstances(
    calendar,
    seriesId,
    new Date(Math.min(now.getTime() - FULL_SYNC_PAST_DAYS * DAY, ...starts) - DAY).toISOString(),
    new Date(Math.max(now.getTime() + FULL_SYNC_FUTURE_DAYS * DAY, ...ends) + DAY).toISOString(),
  )
  return { live, instances }
}

/**
 * Makes the rows of one recurring event match Google's instances: each instance is upserted and a
 * live row Google no longer lists is tombstoned. Google names an instance after its original start
 * time, so a series whose time changed can come back under new ids. The row the client wrote to
 * then takes the instance that starts at `target`: its id is the one the client holds.
 */
async function storeSeries(
  db: Db,
  sync: CalendarSyncService,
  calendar: CalendarRow,
  current: EventRow,
  seriesId: string,
  target: number,
  now: Date,
): Promise<EventRow> {
  const { live, instances } = await readSeries(db, sync, calendar, seriesId, now)
  const held = new Set(live.map((e) => e.googleId))
  const listed = new Set(instances.map((e) => e.id))
  const renamed = listed.has(current.googleId)
    ? undefined
    : instances.find((e) => !held.has(e.id) && e.start?.dateTime !== undefined && new Date(e.start.dateTime).getTime() === target)
  const { profiles, learned } = await learnAccountProfiles(db, instances, now)
  if (learned) await refreshAllDayJudgments(db, now)
  return db.transaction(async (tx) => {
    for (const instance of instances) {
      const row = judgedGoogleEvent(calendar, instance, profiles, now)
      if (instance !== renamed) {
        await tx
          .insert(events)
          .values({ id: randomUUID(), ...row })
          .onConflictDoUpdate({ target: [events.calendarId, events.googleId], set: row })
        continue
      }
      // Another row can hold the instance's id: a tombstone from before the series left this time
      // and came back, or a row a sync wrote meanwhile. The two rows trade ids and the other one
      // stays dead. Deleting it would leave its event on a device that has not synced since.
      const [other] = await tx
        .update(events)
        .set({ googleId: `${current.googleId}:${current.id}`, deletedAt: now, updatedAt: now })
        .where(and(eq(events.calendarId, calendar.id), eq(events.googleId, instance.id), ne(events.id, current.id)))
        .returning({ id: events.id })
      await tx.update(events).set(row).where(eq(events.id, current.id))
      if (other !== undefined) await tx.update(events).set({ googleId: current.googleId }).where(eq(events.id, other.id))
    }
    const stale = live.filter((e) => !listed.has(e.googleId) && !(renamed !== undefined && e.id === current.id)).map((e) => e.id)
    if (stale.length > 0) {
      await tx.update(events).set({ deletedAt: now, updatedAt: now }).where(inArray(events.id, stale))
    }
    const [stored] = await tx.select().from(events).where(eq(events.id, current.id)).limit(1)
    if (stored === undefined) throw notFound(`event ${current.id}`)
    return stored
  })
}

/** The live rows of one recurring event in a calendar. */
function liveSeries(calendarId: string, seriesId: string) {
  return and(eq(events.calendarId, calendarId), eq(events.recurringEventId, seriesId), isNull(events.deletedAt))
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
