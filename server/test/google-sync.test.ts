import { eq, inArray } from 'drizzle-orm'
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import type { Db } from '../src/db/client.js'
import { calendars, events, googleAccounts } from '../src/db/schema.js'
import type { CalendarRow } from '../src/db/schema.js'
import { GoogleApiError, GoogleTokenError, deleteEvent, getEvent, insertEvent, patchEvent, refreshAccessToken } from '../src/google/client.js'
import type { GoogleCalendarListEntry, GoogleEvent } from '../src/google/client.js'
import { GoogleSync, selectedByDefault } from '../src/google/sync.js'
import { createTestDb } from './db.js'
import { testConfig } from './fixtures.js'

function entry(id: string, accessRole: string, extra: Partial<GoogleCalendarListEntry> = {}): GoogleCalendarListEntry {
  return { id, accessRole, ...extra }
}

interface FetchCall {
  url: string
  init: RequestInit & { headers?: Record<string, string> }
}

/** Replaces global `fetch` with one that records every call and answers them from `responses` in order. */
function stubFetch(...responses: Response[]): FetchCall[] {
  const calls: FetchCall[] = []
  vi.stubGlobal('fetch', async (url: string | URL, init: RequestInit = {}) => {
    calls.push({ url: String(url), init: init as FetchCall['init'] })
    const res = responses.shift()
    if (res === undefined) throw new Error(`unexpected fetch ${String(url)}`)
    return res
  })
  return calls
}

afterEach(() => vi.unstubAllGlobals())

const EVENTS_URL = 'https://www.googleapis.com/calendar/v3/calendars/me%40example.com/events'

describe('selectedByDefault', () => {
  it('selects the account’s own primary calendar and writable group calendars', () => {
    expect(selectedByDefault(entry('me@example.com', 'owner', { primary: true }))).toBe(true)
    expect(selectedByDefault(entry('abc123@group.calendar.google.com', 'owner'))).toBe(true)
    expect(selectedByDefault(entry('family@group.calendar.google.com', 'writer'))).toBe(true)
  })

  it('leaves other people’s calendars off even when they granted owner access', () => {
    expect(selectedByDefault(entry('coworker@example.com', 'owner'))).toBe(false)
    expect(selectedByDefault(entry('coworker@example.com', 'writer'))).toBe(false)
    expect(selectedByDefault(entry('boss@example.com', 'reader'))).toBe(false)
  })

  it('leaves read-only, holiday, subscription, and resource calendars off', () => {
    expect(selectedByDefault(entry('shared@group.calendar.google.com', 'reader'))).toBe(false)
    expect(selectedByDefault(entry('en.usa#holiday@group.v.calendar.google.com', 'reader'))).toBe(false)
    expect(selectedByDefault(entry('feed@import.calendar.google.com', 'reader'))).toBe(false)
    expect(selectedByDefault(entry('room-4a@resource.calendar.google.com', 'writer'))).toBe(false)
  })
})

describe('event write requests', () => {
  const event: GoogleEvent = {
    id: 'g-1',
    summary: 'Dentist',
    start: { dateTime: '2026-11-12T15:00:00.000Z' },
    end: { dateTime: '2026-11-12T16:00:00.000Z' },
  }
  const json = { 'content-type': 'application/json', authorization: 'Bearer tok' }

  it('insertEvent POSTs the event with sendUpdates=all and the bearer token', async () => {
    const calls = stubFetch(Response.json(event))
    const body = {
      id: '6f9619ff8b86d011b42d00c04fc964ff',
      summary: 'Dentist',
      location: 'Main St',
      start: { dateTime: '2026-11-12T15:00:00.000Z' },
      end: { dateTime: '2026-11-12T16:00:00.000Z' },
    }
    expect(await insertEvent('tok', 'me@example.com', body)).toEqual(event)
    expect(calls).toHaveLength(1)
    expect(calls[0]!.url).toBe(`${EVENTS_URL}?sendUpdates=all`)
    expect(calls[0]!.init.method).toBe('POST')
    expect(calls[0]!.init.headers).toEqual(json)
    expect(JSON.parse(calls[0]!.init.body as string)).toEqual(body)
  })

  it('patchEvent PATCHes a timed move, an all-day switch with dateTime nulled, and an RSVP attendee list', async () => {
    const timed = { start: { dateTime: '2026-11-13T15:00:00.000Z' }, end: { dateTime: '2026-11-13T16:00:00.000Z' } }
    const allDay = { start: { date: '2026-11-13', dateTime: null }, end: { date: '2026-11-14', dateTime: null } }
    const rsvp = {
      attendees: [
        { email: 'lead@example.com', organizer: true, responseStatus: 'accepted' },
        { email: 'me@example.com', self: true, responseStatus: 'declined' },
      ],
    }
    const calls = stubFetch(Response.json(event), Response.json(event), Response.json(event))
    await patchEvent('tok', 'me@example.com', 'g 1', timed)
    await patchEvent('tok', 'me@example.com', 'g 1', allDay)
    expect(await patchEvent('tok', 'me@example.com', 'g 1', rsvp)).toEqual(event)
    expect(calls).toHaveLength(3)
    for (const call of calls) {
      expect(call.url).toBe(`${EVENTS_URL}/g%201?sendUpdates=all`)
      expect(call.init.method).toBe('PATCH')
      expect(call.init.headers).toEqual(json)
    }
    expect(calls.map((c) => JSON.parse(c.init.body as string))).toEqual([timed, allDay, rsvp])
  })

  it('deleteEvent DELETEs with sendUpdates=all, no body, and accepts an empty 204', async () => {
    const calls = stubFetch(new Response(null, { status: 204 }))
    await expect(deleteEvent('tok', 'me@example.com', 'g-1')).resolves.toBeUndefined()
    expect(calls).toHaveLength(1)
    expect(calls[0]!.url).toBe(`${EVENTS_URL}/g-1?sendUpdates=all`)
    expect(calls[0]!.init.method).toBe('DELETE')
    expect(calls[0]!.init.headers).toEqual({ authorization: 'Bearer tok' })
    expect(calls[0]!.init.body).toBeUndefined()
  })

  it('getEvent GETs one event', async () => {
    const calls = stubFetch(Response.json(event))
    expect(await getEvent('tok', 'me@example.com', 'g-1')).toEqual(event)
    expect(calls[0]!.url).toBe(`${EVENTS_URL}/g-1`)
    expect(calls[0]!.init.method).toBeUndefined()
    expect(calls[0]!.init.headers).toEqual({ authorization: 'Bearer tok' })
  })

  it("carries Google's own message on failures, and only the status when there is none", async () => {
    stubFetch(new Response(JSON.stringify({ error: { code: 400, message: 'Invalid start time.' } }), { status: 400 }))
    const invalid = await insertEvent('tok', 'me@example.com', {}).catch((err: unknown) => err)
    expect(invalid).toBeInstanceOf(GoogleApiError)
    expect(invalid).toMatchObject({ status: 400, message: 'Google API responded 400: Invalid start time.' })

    stubFetch(new Response('<html>bad gateway</html>', { status: 502 }))
    const opaque = await getEvent('tok', 'me@example.com', 'g-1').catch((err: unknown) => err)
    expect(opaque).toMatchObject({ status: 502, message: 'Google API responded 502' })
  })

  it('a refused token refresh is a GoogleTokenError, which the API keeps as 502 rather than a client error', async () => {
    stubFetch(new Response(JSON.stringify({ error: 'invalid_grant', error_description: 'Token has been revoked.' }), { status: 400 }))
    const err = await refreshAccessToken({ clientId: 'c', clientSecret: 's' }, 'rt').catch((e: unknown) => e)
    expect(err).toBeInstanceOf(GoogleTokenError)
    expect(err).toBeInstanceOf(GoogleApiError)
    expect(err).toMatchObject({ status: 400, message: 'Google API responded 400' })
  })
})

describe('GoogleSync event writes', () => {
  let db: Db
  let close: () => Promise<void>
  let sync: GoogleSync
  let calendar: CalendarRow

  beforeAll(async () => {
    ;({ db, close } = await createTestDb())
    await db.insert(googleAccounts).values({
      id: 'acc-1',
      email: 'me@example.com',
      label: 'me',
      refreshTokenEnc: 'enc',
      accessToken: 'live-token',
      accessTokenExpiresAt: new Date(Date.now() + 3_600_000),
    })
    const [row] = await db
      .insert(calendars)
      .values({ id: 'cal-1', accountId: 'acc-1', googleId: 'me@example.com', summary: 'Me', accessRole: 'owner' })
      .returning()
    calendar = row!
    sync = new GoogleSync(db, testConfig)
  })

  afterAll(() => close())

  it('syncs and watches hidden blocking and visible free calendars, skipping inactive calendars', async () => {
    await db.insert(calendars).values([
      { id: 'hidden-busy', accountId: 'acc-1', googleId: 'hidden', summary: 'Hidden', accessRole: 'owner', selected: false, blocksScheduling: true },
      { id: 'visible-free', accountId: 'acc-1', googleId: 'visible', summary: 'Visible', accessRole: 'reader', blocksScheduling: false },
      { id: 'inactive', accountId: 'acc-1', googleId: 'inactive', summary: 'Inactive', accessRole: 'reader', selected: false, blocksScheduling: false },
    ])
    const synced = vi.spyOn(sync, 'syncCalendar').mockResolvedValue()
    const watched = vi.spyOn(sync, 'ensureWatch').mockResolvedValue()
    try {
      const [account] = await db.select().from(googleAccounts).where(eq(googleAccounts.id, 'acc-1'))
      await sync.syncAccount(account!)
      expect(synced.mock.calls.map(([c]) => c.id)).toEqual(['cal-1', 'hidden-busy', 'visible-free'])
      expect(watched.mock.calls.map(([c]) => c.id)).toEqual(['cal-1', 'hidden-busy', 'visible-free'])
      synced.mockClear()
      watched.mockClear()
      await sync.syncAll()
      await sync.ensureAllWatches()
      expect(synced.mock.calls.map(([c]) => c.id).sort()).toEqual(['cal-1', 'hidden-busy', 'visible-free'])
      expect(watched.mock.calls.map(([c]) => c.id).sort()).toEqual(['cal-1', 'hidden-busy', 'visible-free'])
    } finally {
      synced.mockRestore()
      watched.mockRestore()
      await db.delete(calendars).where(inArray(calendars.id, ['hidden-busy', 'visible-free', 'inactive']))
    }
  })

  it("calls Google with the calendar's account token", async () => {
    const calls = stubFetch(Response.json({ id: 'g-1', summary: 'New' }))
    const write = { summary: 'New', start: { date: '2026-11-13' }, end: { date: '2026-11-14' } }
    expect(await sync.createEvent(calendar, write)).toEqual({ id: 'g-1', summary: 'New' })
    expect(calls[0]!.url).toBe(`${EVENTS_URL}?sendUpdates=all`)
    expect(calls[0]!.init.headers).toMatchObject({ authorization: 'Bearer live-token' })
  })

  it('loads every page of recurring instances with the calendar token and bounded dates', async () => {
    const calls = stubFetch(
      Response.json({ items: [{ id: 'first', recurringEventId: 'series' }], nextPageToken: 'page-2' }),
      Response.json({ items: [{ id: 'second', recurringEventId: 'series' }] }),
    )
    expect(await sync.eventInstances(calendar, 'series', '2026-11-01T00:00:00Z', '2027-11-01T00:00:00Z'))
      .toEqual([{ id: 'first', recurringEventId: 'series' }, { id: 'second', recurringEventId: 'series' }])
    expect(calls).toHaveLength(2)
    const url = new URL(calls[1]!.url)
    expect(url.pathname).toBe('/calendar/v3/calendars/me%40example.com/events/series/instances')
    expect(Object.fromEntries(url.searchParams)).toMatchObject({
      timeMin: '2026-11-01T00:00:00Z', timeMax: '2027-11-01T00:00:00Z', pageToken: 'page-2', showDeleted: 'false',
    })
    expect(calls[1]!.init.headers).toMatchObject({ authorization: 'Bearer live-token' })
  })

  it('treats 404 and 410 from events.delete as already deleted and rethrows anything else', async () => {
    stubFetch(new Response(JSON.stringify({ error: { message: 'Not Found' } }), { status: 404 }))
    await expect(sync.deleteEvent(calendar, 'g-missing')).resolves.toBeUndefined()
    stubFetch(new Response(JSON.stringify({ error: { message: 'Resource has been deleted' } }), { status: 410 }))
    await expect(sync.deleteEvent(calendar, 'g-gone')).resolves.toBeUndefined()
    stubFetch(new Response(JSON.stringify({ error: { message: 'Forbidden' } }), { status: 403 }))
    await expect(sync.deleteEvent(calendar, 'g-theirs')).rejects.toThrow('Google API responded 403: Forbidden')
  })

  it.each([true, false, null])('a later sync preserves blocksDay=%s and updates the existing row', async (blocksDay) => {
    const start = new Date('2026-11-12T00:00:00Z')
    const end = new Date('2026-11-13T00:00:00Z')
    await db.insert(events).values({
      id: 'client-chosen-id',
      calendarId: 'cal-1',
      googleId: 'g-app',
      status: 'confirmed',
      summary: 'As created',
      allDay: true,
      blocksDay,
      startAt: start,
      endAt: end,
    })
    const fromGoogle: GoogleEvent = {
      id: 'g-app',
      status: 'confirmed',
      summary: 'As Google has it',
      start: { date: '2026-11-12' },
      end: { date: '2026-11-13' },
    }
    stubFetch(Response.json({ items: [fromGoogle], nextSyncToken: 'tok-1' }))
    await sync.syncCalendar(calendar)
    const rows = await db
      .select({ id: events.id, summary: events.summary, deletedAt: events.deletedAt, blocksDay: events.blocksDay })
      .from(events)
      .where(eq(events.calendarId, 'cal-1'))
    expect(rows).toEqual([{ id: 'client-chosen-id', summary: 'As Google has it', deletedAt: null, blocksDay }])
    await db.delete(events).where(eq(events.id, 'client-chosen-id'))
  })
})
