import { setTimeout as sleep } from 'node:timers/promises'
import { localParts, weekdayOf } from '@florida/scheduler'
import type { Hono } from 'hono'
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import { eq, inArray } from 'drizzle-orm'
import { createApp } from '../src/app.js'
import { ChangeBus } from '../src/changes.js'
import type { Db } from '../src/db/client.js'
import { calendars, categories, events, googleAccounts } from '../src/db/schema.js'
import { runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'
import { FakeSync, testConfig as config } from './fixtures.js'

const WEBHOOK_DEBOUNCE_MS = 20

let db: Db
let close: () => Promise<void>
let app: Hono
let fake: FakeSync
let changes: ChangeBus

beforeAll(async () => {
  ;({ db, close } = await createTestDb())
  await seed(db)
  fake = new FakeSync()
  changes = new ChangeBus()
  app = createApp({
    db,
    config,
    sync: fake,
    reschedule: () => runScheduling(db, config),
    changes,
    webhookDebounceMs: WEBHOOK_DEBOUNCE_MS,
  })
})

afterAll(() => close())

const AUTH = { authorization: `Bearer ${config.API_TOKEN}` }

async function api(path: string, init: RequestInit & { json?: unknown } = {}): Promise<Response> {
  const { json, ...rest } = init
  const headers = new Headers(rest.headers)
  for (const [k, v] of Object.entries(AUTH)) headers.set(k, v)
  if (json !== undefined) headers.set('content-type', 'application/json')
  return app.request(path, { ...rest, headers, ...(json !== undefined ? { body: JSON.stringify(json) } : {}) })
}

/** True when the instant falls inside the seeded `work` schedule (Mon–Fri 09–12, 13–17 Pacific). */
function inWorkWindow(iso: string): boolean {
  const p = localParts(new Date(iso).getTime(), 'America/Los_Angeles')
  const weekday = weekdayOf(p)
  const minutes = p.hour * 60 + p.minute
  const morning = minutes >= 9 * 60 && minutes < 12 * 60
  const afternoon = minutes >= 13 * 60 && minutes < 17 * 60
  return weekday >= 1 && weekday <= 5 && (morning || afternoon)
}

const taskBody = {
  categoryId: 'inbox',
  title: 'Write the report',
  durationMinutes: 60,
  priority: 'high',
  deadlineType: 'none',
}

describe('health and auth', () => {
  it('answers /health without auth', async () => {
    const res = await app.request('/health')
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ok: true })
  })

  it('serves the Search Console verification tag on / only when configured', async () => {
    const plain = await app.request('/')
    expect(plain.status).toBe(200)
    expect(await plain.text()).not.toContain('google-site-verification')

    const verified = createApp({
      db,
      config: { ...config, GOOGLE_SITE_VERIFICATION: 'abc_123-XYZ' },
      sync: fake,
      reschedule: () => runScheduling(db, config),
    })
    const res = await verified.request('/')
    expect(res.status).toBe(200)
    expect(res.headers.get('content-type')).toContain('text/html')
    expect(await res.text()).toContain('<meta name="google-site-verification" content="abc_123-XYZ">')
  })

  it('rejects /api requests without a valid bearer token', async () => {
    expect((await app.request('/api/sync')).status).toBe(401)
    expect((await app.request('/api/sync', { headers: { authorization: 'Bearer nope' } })).status).toBe(401)
    expect(
      (await app.request('/api/sync', { headers: { authorization: `Bearer ${config.API_TOKEN}x` } })).status,
    ).toBe(401)
    const res = await app.request('/api/tasks/t1', { method: 'PUT', body: JSON.stringify(taskBody) })
    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: 'unauthorized' })
  })
})

describe('tasks, sync and tombstones', () => {
  let cursorAfterCreate = ''

  it('returns 400 with issues for an invalid task body', async () => {
    const res = await api('/api/tasks/bad', { method: 'PUT', json: { ...taskBody, durationMinutes: 0, priority: 'urgent' } })
    expect(res.status).toBe(400)
    const body = (await res.json()) as { error: string; issues: { path: unknown[] }[] }
    expect(body.error).toBe('validation failed')
    expect(body.issues.map((i) => i.path.join('.')).sort()).toEqual(['durationMinutes', 'priority'])
  })

  it('returns 400 for an unknown category', async () => {
    const res = await api('/api/tasks/bad', { method: 'PUT', json: { ...taskBody, categoryId: 'nope' } })
    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({ error: 'unknown categoryId nope' })
  })

  it('upserts a task and places it inside the work window', async () => {
    const res = await api('/api/tasks/t1', { method: 'PUT', json: taskBody })
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      task: { id: string; title: string; deletedAt: string | null; completedMinutes: number }
      scheduling: { placements: { taskId: string; start: string; end: string; pinned: boolean }[]; unscheduled: unknown[] }
    }
    expect(body.task).toMatchObject({ id: 't1', title: 'Write the report', deletedAt: null, completedMinutes: 0 })
    expect(body.scheduling.unscheduled).toEqual([])
    const [placement] = body.scheduling.placements
    expect(placement).toBeDefined()
    expect(placement?.taskId).toBe('t1')
    expect(placement?.pinned).toBe(false)
    expect(inWorkWindow(placement!.start)).toBe(true)
    expect(inWorkWindow(new Date(new Date(placement!.end).getTime() - 60_000).toISOString())).toBe(true)
    expect(new Date(placement!.end).getTime() - new Date(placement!.start).getTime()).toBe(60 * 60_000)
  })

  it('GET /api/sync without since returns everything', async () => {
    const res = await api('/api/sync')
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      cursor: string
      schedules: { id: string }[]
      categories: { id: string }[]
      tasks: { id: string; deletedAt: string | null }[]
      events: unknown[]
      placements: { taskId: string }[]
      unscheduled: unknown[]
      accounts: unknown[]
      calendars: unknown[]
    }
    expect(new Date(body.cursor).toISOString()).toBe(body.cursor)
    expect(body.schedules.map((s) => s.id).sort()).toEqual(['personal', 'work'])
    expect(body.categories.map((p) => p.id).sort()).toEqual(['inbox', 'personal', 'work'])
    expect(body.tasks).toEqual([expect.objectContaining({ id: 't1', deletedAt: null })])
    expect(body.events).toEqual([])
    expect(body.placements.map((p) => p.taskId)).toEqual(['t1'])
    expect(body.unscheduled).toEqual([])
    expect(body.accounts).toEqual([])
    expect(body.calendars).toEqual([])
    cursorAfterCreate = body.cursor
  })

  it('GET /api/sync?since=cursor returns no changed rows but the full placements table', async () => {
    const res = await api(`/api/sync?since=${encodeURIComponent(cursorAfterCreate)}`)
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, unknown[]>
    expect(body.schedules).toEqual([])
    expect(body.categories).toEqual([])
    expect(body.tasks).toEqual([])
    expect(body.events).toEqual([])
    expect(body.placements).toHaveLength(1)
  })

  it('rejects a malformed since', async () => {
    expect((await api('/api/sync?since=yesterday')).status).toBe(400)
  })

  it('DELETE produces a tombstone visible to since-based sync and removes placements', async () => {
    const del = await api('/api/tasks/t1', { method: 'DELETE' })
    expect(del.status).toBe(200)
    const delBody = (await del.json()) as { scheduling: { placements: unknown[] } }
    expect(delBody.scheduling.placements).toEqual([])

    const res = await api(`/api/sync?since=${encodeURIComponent(cursorAfterCreate)}`)
    const body = (await res.json()) as { tasks: { id: string; deletedAt: string | null }[]; placements: unknown[] }
    expect(body.tasks).toHaveLength(1)
    expect(body.tasks[0]?.id).toBe('t1')
    expect(body.tasks[0]?.deletedAt).not.toBeNull()
    expect(body.placements).toEqual([])

    expect((await api('/api/tasks/never-existed', { method: 'DELETE' })).status).toBe(404)
  })

  it('GET /api/sync sends the full unscheduled table, even after a cursor, until the task is gone', async () => {
    const cursor = ((await (await api('/api/sync')).json()) as { cursor: string }).cursor
    const dueAt = new Date(Date.now() - 86_400_000).toISOString()
    const put = await api('/api/tasks/overdue', {
      method: 'PUT',
      json: { ...taskBody, title: 'Missed it', durationMinutes: 45, deadlineType: 'hard', dueAt },
    })
    expect(put.status).toBe(200)

    const body = (await (await api(`/api/sync?since=${encodeURIComponent(cursor)}`)).json()) as {
      unscheduled: { taskId: string; reason: string; unplacedMinutes: number; computedAt: string }[]
    }
    expect(body.unscheduled).toEqual([
      { taskId: 'overdue', reason: 'no_fit_before_hard_deadline', unplacedMinutes: 45, computedAt: expect.any(String) },
    ])
    expect(new Date(body.unscheduled[0]!.computedAt).toISOString()).toBe(body.unscheduled[0]!.computedAt)
    const later = (await (await api(`/api/sync?since=${encodeURIComponent(new Date().toISOString())}`)).json()) as {
      unscheduled: unknown[]
    }
    expect(later.unscheduled).toHaveLength(1)

    expect((await api('/api/tasks/overdue', { method: 'DELETE' })).status).toBe(200)
    expect(((await (await api('/api/sync')).json()) as { unscheduled: unknown[] }).unscheduled).toEqual([])
  })

  it('upserts schedules and categories, and tombstones schedules', async () => {
    const sched = await api('/api/schedules/deep', {
      method: 'PUT',
      json: { name: 'Deep work', timeZone: 'America/Los_Angeles', windows: [{ days: [2, 4], start: '08:00', end: '11:00' }] },
    })
    expect(sched.status).toBe(200)
    const badTz = await api('/api/schedules/bad', {
      method: 'PUT',
      json: { name: 'x', timeZone: 'Mars/Olympus', windows: [{ days: [1], start: '08:00', end: '11:00' }] },
    })
    expect(badTz.status).toBe(400)

    const proj = await api('/api/categories/side', { method: 'PUT', json: { name: 'Side', scheduleId: 'deep', color: '#ff0' } })
    expect(proj.status).toBe(200)
    const catBody = (await proj.json()) as { category: { scheduleId: string; sortOrder: number } }
    expect(catBody.category).toMatchObject({ scheduleId: 'deep', sortOrder: 0 })

    const cursor = ((await (await api('/api/sync')).json()) as { cursor: string }).cursor
    expect((await api('/api/schedules/deep', { method: 'DELETE' })).status).toBe(200)
    const after = (await (await api(`/api/sync?since=${encodeURIComponent(cursor)}`)).json()) as {
      schedules: { id: string; deletedAt: string | null }[]
    }
    expect(after.schedules).toEqual([expect.objectContaining({ id: 'deep' })])
    expect(after.schedules[0]?.deletedAt).not.toBeNull()
  })

  it('POST /api/schedule/run returns a scheduler result', async () => {
    const res = await api('/api/schedule/run', { method: 'POST' })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ placements: [], unscheduled: [], late: [] })
  })
})

describe('categories', () => {
  it('refuses to delete the inbox or rename it, but lets its other fields change', async () => {
    const del = await api('/api/categories/inbox', { method: 'DELETE' })
    expect(del.status).toBe(400)
    expect(await del.json()).toEqual({ error: expect.any(String) })

    const rename = await api('/api/categories/inbox', { method: 'PUT', json: { name: 'Later', scheduleId: 'work' } })
    expect(rename.status).toBe(400)
    expect(await rename.json()).toEqual({ error: expect.any(String) })

    const recolor = await api('/api/categories/inbox', {
      method: 'PUT',
      json: { name: 'Inbox', scheduleId: 'personal', color: '#123456', sortOrder: 5 },
    })
    expect(recolor.status).toBe(200)
    expect(((await recolor.json()) as { category: unknown }).category).toMatchObject({
      id: 'inbox',
      name: 'Inbox',
      scheduleId: 'personal',
      color: '#123456',
      sortOrder: 5,
      deletedAt: null,
    })
    const restore = await api('/api/categories/inbox', { method: 'PUT', json: { name: 'Inbox', scheduleId: 'work', sortOrder: 0 } })
    expect(restore.status).toBe(200)
  })

  it('moves the live tasks of a deleted category to the inbox, then tombstones it and reschedules', async () => {
    expect((await api('/api/categories/errands', { method: 'PUT', json: { name: 'Errands', scheduleId: 'personal' } })).status).toBe(200)
    expect((await api('/api/tasks/errand-live', { method: 'PUT', json: { ...taskBody, categoryId: 'errands', title: 'Buy stamps' } })).status).toBe(200)
    expect((await api('/api/tasks/errand-gone', { method: 'PUT', json: { ...taskBody, categoryId: 'errands', title: 'Old' } })).status).toBe(200)
    expect((await api('/api/tasks/errand-gone', { method: 'DELETE' })).status).toBe(200)
    const cursor = ((await (await api('/api/sync')).json()) as { cursor: string }).cursor

    const res = await api('/api/categories/errands', { method: 'DELETE' })
    expect(res.status).toBe(200)
    const scheduling = ((await res.json()) as { scheduling: { placements: { taskId: string; start: string }[] } }).scheduling
    // Now under the inbox, the task follows the work schedule instead of the personal one.
    const placement = scheduling.placements.find((p) => p.taskId === 'errand-live')
    expect(placement).toBeDefined()
    expect(inWorkWindow(placement!.start)).toBe(true)

    const body = (await (await api(`/api/sync?since=${encodeURIComponent(cursor)}`)).json()) as {
      categories: { id: string; deletedAt: string | null }[]
      tasks: { id: string; categoryId: string }[]
    }
    expect(body.categories).toEqual([expect.objectContaining({ id: 'errands', deletedAt: expect.any(String) })])
    expect(body.tasks).toEqual([expect.objectContaining({ id: 'errand-live', categoryId: 'inbox' })])

    expect((await api('/api/categories/never-existed', { method: 'DELETE' })).status).toBe(404)
    expect((await api('/api/tasks/errand-live', { method: 'DELETE' })).status).toBe(200)
  })
})

describe('single-row reads', () => {
  it('return the row exactly as /api/sync sends it, tombstones included, and 404 only for unknown ids', async () => {
    expect((await api('/api/tasks/live-one', { method: 'PUT', json: { ...taskBody, notes: 'n' } })).status).toBe(200)
    const all = (await (await api('/api/sync')).json()) as Record<'tasks' | 'categories' | 'schedules', { id: string }[]>
    const cases: [string, 'tasks' | 'categories' | 'schedules', string][] = [
      ['/api/tasks/live-one', 'tasks', 'live-one'],
      ['/api/tasks/errand-gone', 'tasks', 'errand-gone'],
      ['/api/categories/work', 'categories', 'work'],
      ['/api/categories/errands', 'categories', 'errands'],
      ['/api/schedules/personal', 'schedules', 'personal'],
      ['/api/schedules/deep', 'schedules', 'deep'],
    ]
    for (const [path, table, id] of cases) {
      const res = await api(path)
      expect(res.status, path).toBe(200)
      const row = all[table].find((r) => r.id === id)
      expect(row, path).toBeDefined()
      expect(await res.json(), path).toEqual(row)
    }
    const tombstone = (await (await api('/api/tasks/errand-gone')).json()) as { deletedAt: string | null }
    expect(tombstone.deletedAt).toEqual(expect.any(String))
    expect(((await (await api('/api/schedules/deep')).json()) as { deletedAt: string | null }).deletedAt).toEqual(expect.any(String))

    for (const path of ['/api/tasks/nope', '/api/categories/nope', '/api/schedules/nope']) {
      const res = await api(path)
      expect(res.status, path).toBe(404)
      expect(await res.json(), path).toEqual({ error: expect.any(String) })
    }
    expect((await app.request('/api/tasks/live-one')).status).toBe(401)
    expect((await api('/api/tasks/live-one', { method: 'DELETE' })).status).toBe(200)
  })
})

describe('seed', () => {
  it('creates work and personal once and keeps later edits on a re-seed, while the inbox is reset', async () => {
    const fresh = await createTestDb()
    try {
      await seed(fresh.db)
      const first = await fresh.db.select().from(categories).orderBy(categories.sortOrder)
      expect(first.map((p) => [p.id, p.name, p.scheduleId, p.deletedAt])).toEqual([
        ['inbox', 'Inbox', 'work', null],
        ['work', 'Work', 'work', null],
        ['personal', 'Personal', 'personal', null],
      ])

      const edited = new Date('2026-11-01T00:00:00Z')
      await fresh.db.update(categories).set({ name: 'Day job', color: '#00f', updatedAt: edited }).where(eq(categories.id, 'work'))
      await fresh.db.update(categories).set({ deletedAt: edited, updatedAt: edited }).where(eq(categories.id, 'personal'))
      await fresh.db.update(categories).set({ name: 'Renamed', sortOrder: 9 }).where(eq(categories.id, 'inbox'))
      await seed(fresh.db)

      const rows = Object.fromEntries((await fresh.db.select().from(categories)).map((p) => [p.id, p]))
      expect(rows.work).toMatchObject({ name: 'Day job', color: '#00f', updatedAt: edited, deletedAt: null })
      expect(rows.personal).toMatchObject({ name: 'Personal', deletedAt: edited })
      expect(rows.inbox).toMatchObject({ name: 'Inbox', sortOrder: 0, deletedAt: null })
    } finally {
      await fresh.close()
    }
  })
})

describe('google', () => {
  beforeAll(async () => {
    await db.insert(googleAccounts).values({
      id: 'acc-1',
      email: 'me@example.com',
      label: 'work',
      refreshTokenEnc: 'opaque',
      accessToken: 'should-never-leak',
    })
    await db.insert(calendars).values({
      id: 'cal-1',
      accountId: 'acc-1',
      googleId: 'me@example.com',
      summary: 'Me',
      accessRole: 'owner',
      channelId: 'chan-1',
      channelResourceId: 'res-1',
      channelToken: 'correct-channel-token',
      channelExpiresAt: new Date(Date.now() + 86_400_000),
    })
  })

  const webhook = (headers: Record<string, string>) =>
    app.request('/webhooks/google', { method: 'POST', headers })

  it('ignores webhooks with a wrong channel token or unknown channel', async () => {
    const wrong = await webhook({
      'x-goog-channel-id': 'chan-1',
      'x-goog-channel-token': 'wrong-token',
      'x-goog-resource-state': 'exists',
    })
    expect(wrong.status).toBe(200)
    const unknown = await webhook({
      'x-goog-channel-id': 'chan-unknown',
      'x-goog-channel-token': 'correct-channel-token',
      'x-goog-resource-state': 'exists',
    })
    expect(unknown.status).toBe(200)
    const sync = await webhook({
      'x-goog-channel-id': 'chan-1',
      'x-goog-channel-token': 'correct-channel-token',
      'x-goog-resource-state': 'sync',
    })
    expect(sync.status).toBe(200)
    await sleep(WEBHOOK_DEBOUNCE_MS * 5)
    expect(fake.syncCalendarCalls).toEqual([])
  })

  it('coalesces valid webhooks into one debounced sync of that calendar', async () => {
    const headers = {
      'x-goog-channel-id': 'chan-1',
      'x-goog-channel-token': 'correct-channel-token',
      'x-goog-resource-state': 'exists',
    }
    expect((await webhook(headers)).status).toBe(200)
    expect((await webhook(headers)).status).toBe(200)
    expect(fake.syncCalendarCalls).toEqual([])
    await sleep(WEBHOOK_DEBOUNCE_MS * 5)
    expect(fake.syncCalendarCalls.map((c) => c.id)).toEqual(['cal-1'])
  })

  it('lists accounts with calendars and never exposes tokens', async () => {
    const res = await api('/api/google/accounts')
    expect(res.status).toBe(200)
    const text = await res.text()
    expect(text).not.toContain('should-never-leak')
    expect(text).not.toContain('opaque')
    expect(text).not.toContain('correct-channel-token')
    const body = JSON.parse(text) as { accounts: { email: string; label: string; calendars: { id: string; selected: boolean }[] }[] }
    expect(body.accounts).toEqual([
      expect.objectContaining({ email: 'me@example.com', label: 'work', calendars: [expect.objectContaining({ id: 'cal-1', selected: true })] }),
    ])
  })

  it('GET /api/sync always includes the full accounts and calendars tables without tokens', async () => {
    const cursor = ((await (await api('/api/sync')).json()) as { cursor: string }).cursor
    const res = await api(`/api/sync?since=${encodeURIComponent(cursor)}`)
    expect(res.status).toBe(200)
    const text = await res.text()
    expect(text).not.toContain('should-never-leak')
    expect(text).not.toContain('opaque')
    expect(text).not.toContain('correct-channel-token')
    const body = JSON.parse(text) as {
      tasks: unknown[]
      accounts: { id: string; email: string; label: string; updatedAt: string }[]
      calendars: { id: string; accountId: string; googleId: string; selected: boolean; updatedAt: string }[]
    }
    expect(body.tasks).toEqual([])
    expect(body.accounts).toEqual([expect.objectContaining({ id: 'acc-1', email: 'me@example.com', label: 'work' })])
    expect(body.calendars).toEqual([
      expect.objectContaining({ id: 'cal-1', accountId: 'acc-1', googleId: 'me@example.com', selected: true }),
    ])
    expect(new Date(body.accounts[0]!.updatedAt).toISOString()).toBe(body.accounts[0]!.updatedAt)
  })

  it('deselecting a calendar tombstones its events for clients; selecting re-downloads it', async () => {
    const start = new Date(Date.now() + 2 * 86_400_000)
    const end = new Date(start.getTime() + 3_600_000)
    const event = { status: 'confirmed', startAt: start, endAt: end, allDay: false }
    await db.insert(calendars).values({ id: 'cal-hidden', accountId: 'acc-1', googleId: 'boss@example.com', summary: 'Boss', accessRole: 'reader', selected: false })
    await db.insert(events).values([
      { ...event, id: 'ev-mine', calendarId: 'cal-1', googleId: 'g-mine', summary: 'Mine' },
      { ...event, id: 'ev-old', calendarId: 'cal-1', googleId: 'g-old', summary: 'Gone', deletedAt: new Date('2026-01-01T00:00:00Z') },
      // A deselected calendar's live row (e.g. written by a sync that raced the toggle) never goes out.
      { ...event, id: 'ev-hidden', calendarId: 'cal-hidden', googleId: 'g-hidden', summary: 'Hidden' },
    ])
    await db.update(calendars).set({ syncToken: 'tok-1' }).where(eq(calendars.id, 'cal-1'))
    type SyncEvents = { cursor: string; events: { id: string; deletedAt: string | null }[] }
    const sync = async (since?: string) =>
      (await (await api(since === undefined ? '/api/sync' : `/api/sync?since=${encodeURIComponent(since)}`)).json()) as SyncEvents

    const before = await sync()
    expect(before.events.map((e) => e.id).sort()).toEqual(['ev-mine', 'ev-old'])

    const off = await api('/api/calendars/cal-1', { method: 'PATCH', json: { selected: false } })
    expect(off.status).toBe(200)
    const offBody = (await off.json()) as { calendar: { id: string; selected: boolean }; scheduling: unknown }
    expect(offBody.calendar).toEqual({ id: 'cal-1', googleId: 'me@example.com', selected: false })
    const afterOff = await sync(before.cursor)
    expect(afterOff.events).toEqual([expect.objectContaining({ id: 'ev-mine', deletedAt: expect.any(String) })])
    expect((await sync()).events.map((e) => e.id).sort()).toEqual(['ev-mine', 'ev-old'])
    expect((await sync()).events.every((e) => e.deletedAt !== null)).toBe(true)

    // Push notifications for the deselected calendar no longer trigger a sync.
    const syncsBefore = fake.syncCalendarCalls.length
    const ping = await webhook({
      'x-goog-channel-id': 'chan-1',
      'x-goog-channel-token': 'correct-channel-token',
      'x-goog-resource-state': 'exists',
    })
    expect(ping.status).toBe(200)
    await sleep(WEBHOOK_DEBOUNCE_MS * 5)
    expect(fake.syncCalendarCalls).toHaveLength(syncsBefore)

    const resynced = new Promise<void>((resolve) => {
      let seenNotices = 0
      const unsubscribe = changes.subscribe(() => {
        // One notice for the PATCH reply's reschedule, one after the background sync.
        if (++seenNotices < 2) return
        unsubscribe()
        resolve()
      })
    })
    const on = await api('/api/calendars/cal-1', { method: 'PATCH', json: { selected: true } })
    expect(on.status).toBe(200)
    expect(((await on.json()) as { calendar: unknown }).calendar).toEqual({ id: 'cal-1', googleId: 'me@example.com', selected: true })
    await resynced
    expect(fake.syncCalendarCalls.slice(syncsBefore).map((c) => [c.id, c.syncToken])).toEqual([['cal-1', null]])
    const [stored] = await db.select({ syncToken: calendars.syncToken }).from(calendars).where(eq(calendars.id, 'cal-1'))
    expect(stored?.syncToken).toBeNull()

    expect((await api('/api/calendars/nope', { method: 'PATCH', json: { selected: true } })).status).toBe(404)
    await db.delete(events).where(inArray(events.id, ['ev-mine', 'ev-old', 'ev-hidden']))
    await db.delete(calendars).where(eq(calendars.id, 'cal-hidden'))
  })

  it('POST /api/google/sync syncs everything then reschedules', async () => {
    const res = await api('/api/google/sync', { method: 'POST' })
    expect(res.status).toBe(200)
    expect(fake.syncAllCalls).toBe(1)
    expect(await res.json()).toEqual({ placements: [], unscheduled: [], late: [] })
  })

  it('POST /api/google/resync drops the sync tokens of selected calendars only, then runs a full sync', async () => {
    await db.insert(calendars).values([
      { id: 'cal-resync-on', accountId: 'acc-1', googleId: 'team@group.calendar.google.com', summary: 'Team', accessRole: 'writer', syncToken: 'tok-on' },
      { id: 'cal-resync-off', accountId: 'acc-1', googleId: 'holidays', summary: 'Holidays', accessRole: 'reader', selected: false, syncToken: 'tok-off' },
    ])
    const before = fake.syncAllCalls
    const res = await api('/api/google/resync', { method: 'POST' })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ placements: [], unscheduled: [], late: [] })
    expect(fake.syncAllCalls).toBe(before + 1)
    const tokens = await db
      .select({ id: calendars.id, syncToken: calendars.syncToken })
      .from(calendars)
      .where(inArray(calendars.id, ['cal-resync-on', 'cal-resync-off']))
    expect(Object.fromEntries(tokens.map((t) => [t.id, t.syncToken]))).toEqual({ 'cal-resync-on': null, 'cal-resync-off': 'tok-off' })
    await db.delete(calendars).where(inArray(calendars.id, ['cal-resync-on', 'cal-resync-off']))
  })

  it('guards /auth/google/start with the API token and label format, then redirects to Google', async () => {
    expect((await app.request('/auth/google/start?label=work')).status).toBe(401)
    expect((await app.request('/auth/google/start?label=work&key=wrong')).status).toBe(401)
    expect((await app.request(`/auth/google/start?label=Work!&key=${config.API_TOKEN}`)).status).toBe(400)

    const res = await app.request(`/auth/google/start?label=work&key=${config.API_TOKEN}`)
    expect(res.status).toBe(302)
    const location = new URL(res.headers.get('location') ?? '')
    expect(location.origin + location.pathname).toBe('https://accounts.google.com/o/oauth2/v2/auth')
    expect(location.searchParams.get('client_id')).toBe('client-id')
    expect(location.searchParams.get('redirect_uri')).toBe('https://florida.test/auth/google/callback')
    expect(location.searchParams.get('access_type')).toBe('offline')
    expect(location.searchParams.get('prompt')).toBe('consent')
    expect(location.searchParams.get('state')).toMatch(/^[0-9a-f]{32}$/)

    const bad = await app.request('/auth/google/callback?code=abc&state=not-issued')
    expect(bad.status).toBe(400)
  })

  it('answers /auth/google/callback once the account is stored and runs its first sync in the background', async () => {
    const start = await app.request(`/auth/google/start?label=work&key=${config.API_TOKEN}`)
    const state = new URL(start.headers.get('location') ?? '').searchParams.get('state') ?? ''
    vi.stubGlobal('fetch', async () => Response.json({ access_token: 'access', refresh_token: 'refresh', expires_in: 3600 }))
    let finishSync!: () => void
    fake.syncAccountGate = new Promise<void>((resolve) => {
      finishSync = resolve
    })
    const rescheduled = new Promise<void>((resolve) => {
      const unsubscribe = changes.subscribe(() => {
        unsubscribe()
        resolve()
      })
    })
    try {
      // The sync is still blocked on the gate here, so a response proves it is not on the request path.
      const res = await app.request(`/auth/google/callback?code=abc&state=${state}`)
      expect(res.status).toBe(200)
      expect(await res.text()).toContain('work@example.com')
      expect(fake.syncAccountCalls.map((a) => a.label)).toEqual(['work'])
      expect((await app.request(`/auth/google/callback?code=abc&state=${state}`)).status).toBe(400)
    } finally {
      vi.unstubAllGlobals()
      finishSync()
    }
    await rescheduled
  })
})

describe('change events', () => {
  /** Reads SSE frames from a response body until `count` frames have arrived. */
  async function readFrames(reader: ReadableStreamDefaultReader<Uint8Array>, count: number): Promise<string[]> {
    const decoder = new TextDecoder()
    let buffer = ''
    const frames: string[] = []
    while (frames.length < count) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      let end = buffer.indexOf('\n\n')
      while (end !== -1) {
        frames.push(buffer.slice(0, end))
        buffer = buffer.slice(end + 2)
        end = buffer.indexOf('\n\n')
      }
    }
    return frames
  }

  it('streams a connected event, then a changed event after every scheduler run', async () => {
    const res = await api('/api/events')
    expect(res.status).toBe(200)
    expect(res.headers.get('content-type')).toContain('text/event-stream')
    const reader = res.body!.getReader()
    try {
      const [connected] = await readFrames(reader, 1)
      expect(connected).toMatch(/^event: connected\ndata: \{"at":"/)
      expect(changes.size).toBe(1)

      expect((await api('/api/schedule/run', { method: 'POST' })).status).toBe(200)
      const [changed] = await readFrames(reader, 1)
      expect(changed).toMatch(/^event: changed\ndata: \{"at":"/)
      const notice = JSON.parse(changed!.split('\ndata: ')[1]!) as { at: string }
      expect(new Date(notice.at).toISOString()).toBe(notice.at)
    } finally {
      await reader.cancel()
    }
    await sleep(20)
    expect(changes.size).toBe(0)
  })

  it('requires the bearer token like every other /api route', async () => {
    expect((await app.request('/api/events')).status).toBe(401)
  })
})
