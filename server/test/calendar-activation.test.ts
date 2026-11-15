import { eq, gt, sql } from 'drizzle-orm'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp } from '../src/app.js'
import { ChangeBus } from '../src/changes.js'
import type { Db } from '../src/db/client.js'
import { calendars, events, googleAccounts } from '../src/db/schema.js'
import type { CalendarRow } from '../src/db/schema.js'
import { syncCursor, writeTimestamp } from '../src/db/sync-clock.js'
import { mapEvent } from '../src/google/client.js'
import type { GoogleEvent } from '../src/google/client.js'
import { GoogleSync } from '../src/google/sync.js'
import { createTestDb } from './db.js'
import { testConfig } from './fixtures.js'

const DAY = 86_400_000
const emptySchedule = { placements: [], unscheduled: [], late: [], optional: [], projectPlacements: [] }

function event(id: string, days = 1): GoogleEvent {
  return {
    id, summary: id, status: 'confirmed',
    start: { dateTime: new Date(Date.now() + days * DAY).toISOString() },
    end: { dateTime: new Date(Date.now() + days * DAY + 3_600_000).toISOString() },
  }
}

function gate() {
  let resolve!: () => void
  const promise = new Promise<void>((done) => { resolve = done })
  return { promise, resolve }
}

describe('batched Google sync and bounded calendar activation', () => {
  let db: Db
  let close: () => Promise<void>
  let sync: GoogleSync
  let calendar: CalendarRow

  beforeAll(async () => {
    ;({ db, close } = await createTestDb())
    await db.insert(googleAccounts).values({
      id: 'account', email: 'me@example.com', label: 'Me', refreshTokenEnc: 'unused',
      accessToken: 'live', accessTokenExpiresAt: new Date(Date.now() + DAY),
    })
  })
  beforeEach(async () => {
    await db.delete(events)
    await db.delete(calendars)
    const [row] = await db.insert(calendars).values({
      id: 'calendar', accountId: 'account', googleId: 'coworker@example.com', summary: 'Coworker',
      accessRole: 'reader', selected: false, blocksScheduling: false, syncToken: 'old',
    }).returning()
    calendar = row!
    sync = new GoogleSync(db, testConfig)
  })
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })
  afterAll(() => close())

  function appFor(timeoutMs = 4_000) {
    const reschedule = vi.fn(async () => emptySchedule)
    const changes = new ChangeBus()
    const notice = vi.fn()
    changes.subscribe(notice)
    const app = createApp({ db, config: testConfig, sync, reschedule, changes, calendarPrefetchTimeoutMs: timeoutMs })
    const request = (path: string, body?: unknown) => app.request(path, {
      method: body === undefined ? 'GET' : 'PATCH',
      headers: { authorization: `Bearer ${testConfig.API_TOKEN}`, 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
    return { request, reschedule, notice }
  }

  const storedCalendar = async () => (await db.select().from(calendars).where(eq(calendars.id, 'calendar')))[0]!
  const storedEvents = () => db.select().from(events)
  const active = async () => {
    await db.update(calendars).set({ selected: true, syncToken: null }).where(eq(calendars.id, calendar.id))
  }

  it('upserts 651 unique events in four batches across pages, retaining overrides, tombstones and DB-clock cursor visibility', async () => {
    await active()
    await db.insert(events).values([
      { id: 'override-no', ...mapEvent(calendar.id, event('g-2')), blocksDay: false },
      { id: 'override-yes', ...mapEvent(calendar.id, event('g-3')), blocksDay: true },
      { id: 'stale', ...mapEvent(calendar.id, event('stale')) },
    ])
    const cursor = await syncCursor(db)
    const allDay = { start: { date: '2026-11-15' }, end: { date: '2026-11-16' } }
    const first = Array.from({ length: 620 }, (_, i) => event(`g-${i}`))
    first[2] = { id: 'g-2', summary: 'Company holiday', ...allDay }
    first[3] = { id: 'g-3', summary: 'Birthday', ...allDay }
    const second = Array.from({ length: 31 }, (_, i) => event(`g-${620 + i}`))
    second[10] = { id: 'g-630', status: 'cancelled' }
    const pages = [
      { items: [...first, { ...event('g-1'), summary: 'Duplicate in the same page' }], nextPageToken: 'page-2' },
      { items: [...second, { ...event('g-1'), summary: 'Last page wins' }], nextSyncToken: 'full-token' },
    ]
    const fetch = vi.fn(async () => Response.json(pages.shift()))
    vi.stubGlobal('fetch', fetch)
    const transactions = vi.spyOn(db, 'transaction')
    await sync.syncCalendar(calendar)
    expect(transactions).toHaveBeenCalledTimes(6)
    expect(fetch).toHaveBeenCalledTimes(2)
    const rows = await storedEvents()
    expect(rows).toHaveLength(652)
    expect(rows.find((row) => row.googleId === 'g-1')?.summary).toBe('Last page wins')
    expect(rows.find((row) => row.googleId === 'g-2')).toMatchObject({ id: 'override-no', blocksDay: false, autoBlocksDay: true, blockingReason: 'Company holiday' })
    expect(rows.find((row) => row.googleId === 'g-3')).toMatchObject({ id: 'override-yes', blocksDay: true, autoBlocksDay: false, blockingReason: 'Birthday or anniversary' })
    expect(rows.find((row) => row.googleId === 'g-630')).toMatchObject({ status: 'cancelled', startAt: null, endAt: null, deletedAt: expect.any(Date) })
    expect(rows.find((row) => row.googleId === 'stale')?.deletedAt).toBeInstanceOf(Date)
    expect(await db.select().from(events).where(gt(events.updatedAt, cursor))).toHaveLength(652)
    expect(await storedCalendar()).toMatchObject({ syncToken: 'full-token', lastSyncedAt: expect.any(Date) })
  })

  it('returns near-window events in the very first delta after PATCH, then completes the year, token, tombstones and watch', async () => {
    const fullGate = gate()
    const fullStarted = gate()
    const fetch = vi.fn(async (input: string | URL) => {
      const url = new URL(input)
      if (url.pathname.endsWith('/watch')) return Response.json({ resourceId: 'watch', expiration: String(Date.now() + 7 * DAY) })
      if (url.searchParams.get('showDeleted') === 'false') {
        return Response.json({ items: [event('near')], nextSyncToken: 'must-not-store-near-token' })
      }
      fullStarted.resolve()
      await fullGate.promise
      return Response.json({ items: [event('near'), event('far', 300), { id: 'cancelled', status: 'cancelled' }], nextSyncToken: 'full-token' })
    })
    vi.stubGlobal('fetch', fetch)
    const { request, reschedule, notice } = appFor()
    const cursor = (await (await request('/api/sync')).json()).cursor as string
    const startedAt = Date.now()
    const response = await request('/api/calendars/calendar', { selected: true })
    expect(response.status).toBe(200)
    await fullStarted.promise
    expect(await storedCalendar()).toMatchObject({ syncToken: null, lastSyncedAt: null })
    const delta = await (await request(`/api/sync?since=${encodeURIComponent(cursor)}`)).json()
    expect(delta.events).toEqual([expect.objectContaining({ googleId: 'near', deletedAt: null })])
    expect(reschedule).toHaveBeenCalledTimes(1)
    expect(notice).toHaveBeenCalledTimes(1)
    const near = new URL(String(fetch.mock.calls[0]![0]))
    const full = new URL(String(fetch.mock.calls[1]![0]))
    for (const [url, past, future] of [[near, 7, 45], [full, 30, 365]] as const) {
      expect(Math.abs(Date.parse(url.searchParams.get('timeMin')!) - (startedAt - past * DAY))).toBeLessThan(2_000)
      expect(Math.abs(Date.parse(url.searchParams.get('timeMax')!) - (startedAt + future * DAY))).toBeLessThan(2_000)
      expect(url.searchParams.has('syncToken')).toBe(false)
    }
    expect(full.searchParams.has('showDeleted')).toBe(false)
    fullGate.resolve()
    await vi.waitFor(async () => expect((await storedCalendar()).channelResourceId).toBe('watch'))
    expect(await storedCalendar()).toMatchObject({ syncToken: 'full-token', lastSyncedAt: expect.any(Date) })
    expect((await storedEvents()).map((row) => row.googleId).sort()).toEqual(['cancelled', 'far', 'near'])
    expect(reschedule).toHaveBeenCalledTimes(2)
    expect(notice).toHaveBeenCalledTimes(2)
  })

  it('never prunes existing events or records partial-window sync metadata during prefetch', async () => {
    await active()
    await db.update(calendars).set({ lastSyncedAt: new Date('2026-01-01') })
    await db.insert(events).values({ id: 'far', ...mapEvent(calendar.id, event('far', 300)), blocksDay: true })
    vi.stubGlobal('fetch', vi.fn(async () => Response.json({ items: [event('near')], nextSyncToken: 'partial' })))
    await sync.prefetchCalendar(calendar.id, new AbortController().signal)
    expect(await storedCalendar()).toMatchObject({ syncToken: null, lastSyncedAt: new Date('2026-01-01') })
    expect((await storedEvents()).find((row) => row.googleId === 'near')).toMatchObject({ deletedAt: null })
    expect((await storedEvents()).find((row) => row.id === 'far')).toMatchObject({ deletedAt: null, blocksDay: true })
  })

  it.each(['fails', 'times out'])('still completes Stage 2 when Stage 1 %s, without late prefetch overwrites', async (failure) => {
    const nearGate = gate()
    const nearFinished = gate()
    let signal: AbortSignal | null | undefined
    const fetch = vi.fn(async (input: string | URL, init?: RequestInit) => {
      const url = new URL(input)
      if (url.pathname.endsWith('/watch')) return Response.json({ resourceId: 'watch' })
      if (url.searchParams.get('showDeleted') === 'false') {
        signal = init?.signal
        if (failure === 'fails') return new Response('unavailable', { status: 503 })
        await nearGate.promise
        nearFinished.resolve()
        return Response.json({ items: [{ ...event('near'), summary: 'Old prefetch' }] })
      }
      return Response.json({ items: [{ ...event('near'), summary: 'Full copy' }, event('far', 300)], nextSyncToken: 'full-token' })
    })
    vi.stubGlobal('fetch', fetch)
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { request } = appFor(25)
    expect((await request('/api/calendars/calendar', { selected: true })).status).toBe(200)
    await vi.waitFor(async () => expect((await storedCalendar()).channelResourceId).toBe('watch'))
    expect(signal?.aborted).toBe(true)
    nearGate.resolve()
    if (failure === 'times out') await nearFinished.promise
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect((await storedEvents()).find((row) => row.googleId === 'near')?.summary).toBe('Full copy')
    expect(await storedCalendar()).toMatchObject({ syncToken: 'full-token', lastSyncedAt: expect.any(Date) })
  })

  it('fences a deactivation during Stage 1, skips Stage 2 and returns the current selection', async () => {
    const nearGate = gate()
    const nearStarted = gate()
    const fetch = vi.fn(async () => {
      nearStarted.resolve()
      await nearGate.promise
      return Response.json({ items: [event('obsolete')], nextSyncToken: 'obsolete' })
    })
    vi.stubGlobal('fetch', fetch)
    const { request } = appFor()
    const activation = request('/api/calendars/calendar', { selected: true })
    await nearStarted.promise
    expect((await request('/api/calendars/calendar', { selected: false })).status).toBe(200)
    nearGate.resolve()
    expect(await (await activation).json()).toMatchObject({ calendar: { selected: false, blocksScheduling: false } })
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(await storedEvents()).toEqual([])
    expect(await storedCalendar()).toMatchObject({ selected: false, syncToken: null, lastSyncedAt: null })
  })

  it('fences an obsolete full sync after deactivation and reactivation, preserving the new token and manual override', async () => {
    await active()
    await db.insert(events).values({ id: 'held', ...mapEvent(calendar.id, event('near')), blocksDay: false })
    const oldGate = gate()
    const oldStarted = gate()
    let calls = 0
    vi.stubGlobal('fetch', vi.fn(async (input: string | URL) => {
      const url = new URL(input)
      if (url.pathname.endsWith('/watch')) return Response.json({ resourceId: 'watch' })
      if (++calls === 1) {
        oldStarted.resolve()
        await oldGate.promise
        return Response.json({ items: [{ ...event('near'), summary: 'Obsolete' }], nextSyncToken: 'obsolete-token' })
      }
      return Response.json({ items: [{ ...event('near'), summary: 'Current' }], nextSyncToken: 'current-token' })
    }))
    const old = sync.syncCalendar(calendar)
    await oldStarted.promise
    const { request } = appFor()
    await request('/api/calendars/calendar', { selected: false })
    await db.update(events).set({ blocksDay: true, updatedAt: writeTimestamp }).where(eq(events.id, 'held'))
    const on = request('/api/calendars/calendar', { selected: true })
    await vi.waitFor(async () => expect((await storedCalendar()).selected).toBe(true))
    oldGate.resolve()
    expect((await on).status).toBe(200)
    await old
    await vi.waitFor(async () => expect((await storedCalendar()).channelResourceId).toBe('watch'))
    expect(await storedCalendar()).toMatchObject({ selected: true, syncToken: 'current-token' })
    expect((await storedEvents())[0]).toMatchObject({ id: 'held', blocksDay: true, summary: 'Current', deletedAt: null })
  })

  it('restarts an expired incremental token with a full sync and keeps tombstones visible to the cursor', async () => {
    await active()
    await db.update(calendars).set({ syncToken: 'expired' })
    await db.insert(events).values({ id: 'old', ...mapEvent(calendar.id, event('old')), blocksDay: true })
    const cursor = await syncCursor(db)
    const fetch = vi.fn()
      .mockResolvedValueOnce(new Response('expired', { status: 410 }))
      .mockResolvedValueOnce(Response.json({ items: [event('new')], nextSyncToken: 'fresh' }))
    vi.stubGlobal('fetch', fetch)
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    await sync.syncCalendar(calendar)
    expect(new URL(fetch.mock.calls[0]![0] as string).searchParams.get('syncToken')).toBe('expired')
    expect(new URL(fetch.mock.calls[1]![0] as string).searchParams.has('timeMin')).toBe(true)
    expect(await storedCalendar()).toMatchObject({ syncToken: 'fresh', lastSyncedAt: expect.any(Date) })
    expect((await db.select().from(events).where(gt(events.updatedAt, cursor))).find((row) => row.id === 'old'))
      .toMatchObject({ blocksDay: true, deletedAt: expect.any(Date) })
  })

  it.each(['near', 'full'])('serializes overlapping near/full pagination when %s starts first', async (first) => {
    await active()
    const held = gate()
    const started = gate()
    const fetch = vi.fn(async (input: string | URL) => {
      const url = new URL(input)
      const near = url.searchParams.get('showDeleted') === 'false'
      if (near) {
        started.resolve()
        await held.promise
        return Response.json({ items: [{ ...event('near'), summary: 'Old near snapshot' }] })
      }
      if (first === 'full' && !url.searchParams.has('pageToken')) {
        return Response.json({ items: [{ ...event('near'), summary: 'New full snapshot' }], nextPageToken: 'page-2' })
      }
      started.resolve()
      await held.promise
      return Response.json({ items: [{ ...event('near'), summary: 'New full snapshot' }], nextSyncToken: 'new-token' })
    })
    vi.stubGlobal('fetch', fetch)
    const controller = new AbortController()
    const initial = first === 'near' ? sync.prefetchCalendar(calendar.id, controller.signal) : sync.syncCalendar(calendar)
    await started.promise
    const following = first === 'near' ? sync.syncCalendar(calendar) : sync.prefetchCalendar(calendar.id, controller.signal)
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(fetch).toHaveBeenCalledTimes(first === 'near' ? 1 : 2)
    held.resolve()
    await Promise.all([initial, following])
    expect((await storedEvents())[0]?.summary).toBe('New full snapshot')
    expect(await storedCalendar()).toMatchObject({ syncToken: 'new-token', lastSyncedAt: expect.any(Date) })
    if (first === 'full') expect(fetch).toHaveBeenCalledTimes(2)
  })

  it.each(['active PATCH', 'watch renewal'])('retries full sync invalidated by %s instead of silently abandoning it', async (change) => {
    await active()
    const held = gate()
    const started = gate()
    let eventCalls = 0
    vi.stubGlobal('fetch', vi.fn(async (input: string | URL) => {
      if (String(input).endsWith('/watch')) return Response.json({ resourceId: 'watch' })
      if (++eventCalls === 1) {
        started.resolve()
        await held.promise
        return Response.json({ items: [{ ...event('near'), summary: 'Obsolete' }], nextSyncToken: 'obsolete-token' })
      }
      return Response.json({ items: [{ ...event('near'), summary: 'Current' }], nextSyncToken: 'current-token' })
    }))
    const running = sync.syncCalendar(calendar)
    await started.promise
    if (change === 'active PATCH') {
      const { request } = appFor()
      expect((await request('/api/calendars/calendar', { blocksScheduling: true })).status).toBe(200)
    } else {
      await sync.ensureWatch(calendar)
    }
    held.resolve()
    await running
    expect(eventCalls).toBe(2)
    expect((await storedEvents())[0]?.summary).toBe('Current')
    expect(await storedCalendar()).toMatchObject({ syncToken: 'current-token', lastSyncedAt: expect.any(Date) })
  })

  it('does not store a watch response over a concurrent deactivation', async () => {
    await active()
    const watchGate = gate()
    const watchStarted = gate()
    const fetch = vi.fn(async (input: string | URL) => {
      if (String(input).endsWith('/channels/stop')) return new Response(null, { status: 204 })
      watchStarted.resolve()
      await watchGate.promise
      return Response.json({ resourceId: 'obsolete-watch' })
    })
    vi.stubGlobal('fetch', fetch)
    const watch = sync.ensureWatch(calendar)
    await watchStarted.promise
    const { request } = appFor()
    await request('/api/calendars/calendar', { selected: false })
    watchGate.resolve()
    await watch
    expect(await storedCalendar()).toMatchObject({ selected: false, channelId: null, channelResourceId: null })
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('uses distinct calendar revisions even for rapid same-millisecond toggles', async () => {
    const { request } = appFor()
    await db.update(calendars).set({ updatedAt: new Date(Date.now() + DAY) })
    const before = (await db.select({ version: sql<string>`${calendars.updatedAt}::text` }).from(calendars))[0]!.version
    await request('/api/calendars/calendar', { selected: false })
    const after = (await db.select({ version: sql<string>`${calendars.updatedAt}::text` }).from(calendars))[0]!.version
    expect(new Date(after).getTime()).toBe(new Date(before).getTime() + 1)
  })
})
