import { eq, inArray } from 'drizzle-orm'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createApp } from '../src/app.js'
import { ChangeBus } from '../src/changes.js'
import { calendars, events, googleAccounts } from '../src/db/schema.js'
import { mapEvent } from '../src/google/client.js'
import type { GoogleEvent } from '../src/google/client.js'
import { GoogleSync } from '../src/google/sync.js'
import { createTestDb } from './db.js'
import { FakeSync, testConfig } from './fixtures.js'

const headers = { authorization: `Bearer ${testConfig.API_TOKEN}`, 'content-type': 'application/json' }
const noScheduling = { placements: [], unscheduled: [], late: [], optional: [], projectPlacements: [] }
type SyncResponse = { cursor: string; events: { id: string; deletedAt: string | null }[] }

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('event sync scope', () => {
  it('sends visible or blocking events and every tombstone, respecting incremental cursor boundaries', async () => {
    const { db, close } = await createTestDb()
    try {
      await db.insert(googleAccounts).values({ id: 'account', email: 'me@example.com', label: 'me', refreshTokenEnc: 'unused' })
      await db.insert(calendars).values([
        { id: 'visible', accountId: 'account', googleId: 'visible', summary: 'Visible only', accessRole: 'reader', blocksScheduling: false },
        { id: 'blocking', accountId: 'account', googleId: 'blocking', summary: 'Hidden blocker', accessRole: 'reader', selected: false },
        { id: 'inactive', accountId: 'account', googleId: 'inactive', summary: 'Inactive', accessRole: 'reader', selected: false, blocksScheduling: false },
      ])
      const old = new Date('2026-01-01T00:00:00Z')
      const event = { status: 'confirmed', allDay: false, startAt: old, endAt: new Date(old.getTime() + 3_600_000), updatedAt: old }
      await db.insert(events).values([
        { ...event, id: 'visible', googleId: 'visible', calendarId: 'visible' },
        { ...event, id: 'blocking', googleId: 'blocking', calendarId: 'blocking' },
        { ...event, id: 'inactive', googleId: 'inactive', calendarId: 'inactive' },
        { ...event, id: 'deleted', googleId: 'deleted', calendarId: 'inactive', deletedAt: old },
        { ...event, id: 'old-deleted', googleId: 'old-deleted', calendarId: 'inactive', deletedAt: old },
        { ...event, id: 'unchanged', googleId: 'unchanged', calendarId: 'blocking' },
        { ...event, id: 'boundary', googleId: 'boundary', calendarId: 'visible' },
      ])
      const app = createApp({ db, config: testConfig, sync: new FakeSync(), reschedule: async () => noScheduling })
      const full = await app.request('/api/sync', { headers })
      expect(full.status).toBe(200)
      const first = await full.json() as SyncResponse
      expect(first.events.map((e) => e.id).sort()).toEqual(['blocking', 'boundary', 'deleted', 'old-deleted', 'unchanged', 'visible'])
      await db.update(events).set({ updatedAt: new Date(Date.parse(first.cursor) + 1) })
        .where(inArray(events.id, ['visible', 'blocking', 'inactive', 'deleted']))
      await db.update(events).set({ updatedAt: new Date(first.cursor) }).where(eq(events.id, 'boundary'))
      const incremental = await app.request(`/api/sync?since=${encodeURIComponent(first.cursor)}`, { headers })
      expect(incremental.status).toBe(200)
      const next = await incremental.json() as SyncResponse
      expect(next.events.map((e) => e.id).sort()).toEqual(['blocking', 'deleted', 'visible'])
      expect(next.events.find((e) => e.id === 'deleted')?.deletedAt).toBe(old.toISOString())
      expect(await db.select({ id: events.id }).from(events)).toHaveLength(7)
    } finally {
      await close()
    }
  })

  it.each([{ selected: true }, { blocksScheduling: true }])('backfills an inactive calendar through the saved cursor when enabling %j', async (patch) => {
    const { db, close } = await createTestDb()
    try {
      vi.useFakeTimers({ toFake: ['Date'] })
      await db.insert(googleAccounts).values({ id: 'account', email: 'me@example.com', label: 'me', refreshTokenEnc: 'unused',
        accessToken: 'test-access-token', accessTokenExpiresAt: new Date(Date.now() + 3_600_000) })
      await db.insert(calendars).values({ id: 'inactive', accountId: 'account', googleId: 'me@example.com', summary: 'Inactive',
        accessRole: 'reader', selected: false, blocksScheduling: false, syncToken: 'stale-token' })
      const googleEvent: GoogleEvent = { id: 'retained', status: 'confirmed', summary: 'Unchanged in Google', updated: '2025-01-01T00:00:00Z',
        start: { dateTime: new Date(Date.now() + 86_400_000).toISOString() },
        end: { dateTime: new Date(Date.now() + 90_000_000).toISOString() } }
      const old = new Date('2025-01-01T00:00:00Z')
      await db.insert(events).values([
        { id: 'retained', ...mapEvent('inactive', googleEvent, old) },
        { id: 'gone', ...mapEvent('inactive', { ...googleEvent, id: 'gone' }, old) },
      ])
      const calls: URL[] = []
      let releaseFetch!: () => void
      let markFetchStarted!: () => void
      const responseReady = new Promise<void>((resolve) => { releaseFetch = resolve })
      const fetchStarted = new Promise<void>((resolve) => { markFetchStarted = resolve })
      vi.stubGlobal('fetch', async (url: string | URL) => {
        calls.push(new URL(url))
        markFetchStarted()
        await responseReady
        return Response.json({ items: [googleEvent], nextSyncToken: 'fresh-token' })
      })
      const changes = new ChangeBus()
      const app = createApp({ db, config: testConfig, sync: new GoogleSync(db, testConfig), changes, reschedule: async () => noScheduling })
      const first = await (await app.request('/api/sync', { headers })).json() as SyncResponse
      expect(first.events).toEqual([])
      const resynced = new Promise<void>((resolve) => {
        let notices = 0
        const unsubscribe = changes.subscribe(() => {
          if (++notices < 2) return
          unsubscribe()
          resolve()
        })
      })
      const activated = await app.request('/api/calendars/inactive', { method: 'PATCH', headers, body: JSON.stringify(patch) })
      expect(activated.status).toBe(200)
      await fetchStarted
      vi.setSystemTime(Date.now() + 1000)
      const during = await (await app.request(`/api/sync?since=${encodeURIComponent(first.cursor)}`, { headers })).json() as SyncResponse
      expect(during.events).toEqual([])
      vi.setSystemTime(Date.now() + 1000)
      releaseFetch()
      await resynced
      expect(calls).toHaveLength(1)
      expect(calls[0]?.searchParams.has('syncToken')).toBe(false)
      expect(calls[0]?.searchParams.has('timeMin')).toBe(true)
      const next = await (await app.request(`/api/sync?since=${encodeURIComponent(during.cursor)}`, { headers })).json() as SyncResponse
      expect(next.events.map((e) => e.id).sort()).toEqual(['gone', 'retained'])
      expect(next.events.find((e) => e.id === 'retained')?.deletedAt).toBeNull()
      expect(next.events.find((e) => e.id === 'gone')?.deletedAt).toEqual(expect.any(String))
    } finally {
      await close()
    }
  })
})
