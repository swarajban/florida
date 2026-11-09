import { setTimeout as sleep } from 'node:timers/promises'
import { localParts, weekdayOf } from '@florida/scheduler'
import type { Hono } from 'hono'
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import { eq, inArray } from 'drizzle-orm'
import { createApp } from '../src/app.js'
import { ChangeBus } from '../src/changes.js'
import type { Db } from '../src/db/client.js'
import { calendars, categories, events, googleAccounts, routineBlocks, settings } from '../src/db/schema.js'
import type { EventBody } from '../src/events.js'
import { GoogleApiError, GoogleGoneError, GoogleTokenError, mapEvent } from '../src/google/client.js'
import type { GoogleEvent, GoogleEventAttendee } from '../src/google/client.js'
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

/** Wall-clock bounds of the seeded routine blocks by weekday (Pacific): home Mon/Thu/Fri, office Tue/Wed. */
const ROUTINE_HOURS: Record<number, [start: number, end: number]> = {
  1: [9 * 60, 15 * 60 + 30],
  2: [10 * 60 + 15, 16 * 60 + 20],
  3: [9 * 60, 16 * 60 + 20],
  4: [9 * 60, 15 * 60 + 30],
  5: [9 * 60, 15 * 60 + 30],
}

/** True when the instant falls inside one of the seeded routine blocks. */
function inRoutine(iso: string): boolean {
  const p = localParts(new Date(iso).getTime(), 'America/Los_Angeles')
  const hours = ROUTINE_HOURS[weekdayOf(p)]
  if (hours === undefined) return false
  const minutes = p.hour * 60 + p.minute
  return minutes >= hours[0] && minutes < hours[1]
}

/** Weekday (0 = Sunday) of the instant in Pacific time. */
function weekdayIn(iso: string): number {
  return weekdayOf(localParts(new Date(iso).getTime(), 'America/Los_Angeles'))
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
    expect(inRoutine(placement!.start)).toBe(true)
    expect(inRoutine(new Date(new Date(placement!.end).getTime() - 60_000).toISOString())).toBe(true)
    expect(new Date(placement!.end).getTime() - new Date(placement!.start).getTime()).toBe(60 * 60_000)
  })

  it('GET /api/sync without since returns everything', async () => {
    const res = await api('/api/sync')
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      cursor: string
      settings: { id: string; timeZone: string } | null
      routineBlocks: { id: string; days: number[]; start: string; end: string; allows: string[] }[]
      schedules: { id: string }[]
      categories: { id: string; area: string | null }[]
      tasks: { id: string; context: string; deletedAt: string | null }[]
      events: unknown[]
      placements: { taskId: string }[]
      unscheduled: unknown[]
      accounts: unknown[]
      calendars: unknown[]
    }
    expect(new Date(body.cursor).toISOString()).toBe(body.cursor)
    expect(body.settings).toMatchObject({ id: 'default', timeZone: 'America/Los_Angeles' })
    expect(body.routineBlocks.map((b) => [b.id, b.days, b.start, b.end, b.allows]).sort()).toEqual([
      ['home', [1, 4, 5], '09:00', '15:30', ['computer', 'errand', 'home']],
      ['office-tue', [2], '10:15', '16:20', ['computer', 'office']],
      ['office-wed', [3], '09:00', '16:20', ['computer', 'office']],
    ])
    expect(body.schedules.map((s) => s.id).sort()).toEqual(['personal', 'work'])
    expect(body.categories.map((p) => [p.id, p.area]).sort()).toEqual([
      ['inbox', null],
      ['personal', 'personal'],
      ['work', 'work'],
    ])
    expect(body.tasks).toEqual([expect.objectContaining({ id: 't1', context: 'computer', deletedAt: null })])
    expect(body.events).toEqual([])
    expect(body.placements.map((p) => p.taskId)).toEqual(['t1'])
    expect(body.unscheduled).toEqual([])
    expect(body.accounts).toEqual([])
    expect(body.calendars).toEqual([])
    cursorAfterCreate = body.cursor
  })

  it('GET /api/sync?since=cursor returns no changed rows but the full placements table and settings', async () => {
    const res = await api(`/api/sync?since=${encodeURIComponent(cursorAfterCreate)}`)
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, unknown[]> & { settings: unknown }
    expect(body.settings).toMatchObject({ timeZone: 'America/Los_Angeles' })
    expect(body.routineBlocks).toEqual([])
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

  it('stores the task context, defaulting to computer and keeping it when an older client omits it', async () => {
    const read = async (res: Response) => ((await res.json()) as { task: { context: string } }).task.context

    expect(await read(await api('/api/tasks/ups-return', { method: 'PUT', json: { ...taskBody, context: 'errand' } }))).toBe('errand')
    // A shipped client that predates `context` sends the body without it; the stored value must survive its edit.
    expect(await read(await api('/api/tasks/ups-return', { method: 'PUT', json: { ...taskBody, title: 'UPS return' } }))).toBe('errand')
    expect(await read(await api('/api/tasks/desk', { method: 'PUT', json: taskBody }))).toBe('computer')

    const bad = await api('/api/tasks/bad', { method: 'PUT', json: { ...taskBody, context: 'moon' } })
    expect(bad.status).toBe(400)
    expect(((await bad.json()) as { issues: { path: unknown[] }[] }).issues.map((i) => i.path.join('.'))).toEqual(['context'])

    for (const id of ['ups-return', 'desk']) expect((await api(`/api/tasks/${id}`, { method: 'DELETE' })).status).toBe(200)
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

    const proj = await api('/api/categories/side', { method: 'PUT', json: { name: 'Side', scheduleId: 'deep', color: '#ff0', area: 'work' } })
    expect(proj.status).toBe(200)
    const catBody = (await proj.json()) as { category: { scheduleId: string; sortOrder: number; area: string | null } }
    expect(catBody.category).toMatchObject({ scheduleId: 'deep', sortOrder: 0, area: 'work' })
    const noArea = await api('/api/categories/side', { method: 'PUT', json: { name: 'Side', scheduleId: 'deep' } })
    expect(((await noArea.json()) as { category: { area: string | null } }).category.area).toBeNull()
    expect((await api('/api/categories/side', { method: 'PUT', json: { name: 'Side', scheduleId: 'deep', area: 'hobby' } })).status).toBe(400)

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
    // Now under the inbox, the task is still placed; only its own context decides where.
    const placement = scheduling.placements.find((p) => p.taskId === 'errand-live')
    expect(placement).toBeDefined()
    expect(inRoutine(placement!.start)).toBe(true)

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

describe('unseeded database', () => {
  it('creates the inbox on the deleted category\'s schedule when deleting a category', async () => {
    const fresh = await createTestDb()
    try {
      const freshApp = createApp({
        db: fresh.db,
        config,
        sync: new FakeSync(),
        reschedule: () => runScheduling(fresh.db, config),
        changes: new ChangeBus(),
      })
      const call = (path: string, method: string, json?: unknown): Promise<Response> =>
        freshApp.request(path, {
          method,
          headers: { ...AUTH, 'content-type': 'application/json' },
          ...(json === undefined ? {} : { body: JSON.stringify(json) }),
        })
      const schedule = { name: 'Evenings', timeZone: 'America/Los_Angeles', windows: [{ days: [1], start: '18:00', end: '21:00' }] }
      expect((await call('/api/schedules/evenings', 'PUT', schedule)).status).toBe(200)
      expect((await call('/api/categories/errands', 'PUT', { name: 'Errands', scheduleId: 'evenings' })).status).toBe(200)
      expect((await call('/api/tasks/stamps', 'PUT', { ...taskBody, categoryId: 'errands' })).status).toBe(200)

      expect((await call('/api/categories/errands', 'DELETE')).status).toBe(200)

      const rows = Object.fromEntries((await fresh.db.select().from(categories)).map((p) => [p.id, p]))
      expect(rows.inbox).toMatchObject({ name: 'Inbox', scheduleId: 'evenings', deletedAt: null })
      expect(rows.errands?.deletedAt).toBeInstanceOf(Date)
      const task = await (await call('/api/tasks/stamps', 'GET')).json() as { categoryId: string }
      expect(task.categoryId).toBe('inbox')
    } finally {
      await fresh.close()
    }
  })
})

describe('routine and settings', () => {
  type Scheduling = {
    placements: { taskId: string; start: string }[]
    unscheduled: { taskId: string; reason: string; unplacedMinutes: number }[]
  }
  const seededHome = { name: 'Home', days: [1, 4, 5], start: '09:00', end: '15:30', allows: ['computer', 'errand', 'home'] }

  it('places an errand only in the home block, drops it while that block is deleted, and places it again once restored', async () => {
    expect((await api('/api/tasks/desk-work', { method: 'PUT', json: { ...taskBody, title: 'Desk work' } })).status).toBe(200)
    const put = await api('/api/tasks/ups-return', { method: 'PUT', json: { ...taskBody, title: 'UPS return', context: 'errand' } })
    expect(put.status).toBe(200)
    const first = ((await put.json()) as { scheduling: Scheduling }).scheduling.placements.find((p) => p.taskId === 'ups-return')
    expect(first).toBeDefined()
    expect([1, 4, 5]).toContain(weekdayIn(first!.start))
    expect(inRoutine(first!.start)).toBe(true)

    const cursor = ((await (await api('/api/sync')).json()) as { cursor: string }).cursor
    const del = await api('/api/routine-blocks/home', { method: 'DELETE' })
    expect(del.status).toBe(200)
    const afterDelete = ((await del.json()) as { scheduling: Scheduling }).scheduling
    // The computer task still fits the office blocks; only the errand has nowhere to go.
    expect(afterDelete.placements.map((p) => p.taskId)).toEqual(['desk-work'])
    expect(afterDelete.unscheduled).toEqual([{ taskId: 'ups-return', reason: 'no_allowed_block', unplacedMinutes: 60 }])

    const synced = (await (await api(`/api/sync?since=${encodeURIComponent(cursor)}`)).json()) as {
      routineBlocks: { id: string; deletedAt: string | null }[]
      unscheduled: { taskId: string }[]
    }
    expect(synced.routineBlocks).toEqual([expect.objectContaining({ id: 'home', deletedAt: expect.any(String) })])
    expect(synced.unscheduled.map((u) => u.taskId)).toEqual(['ups-return'])
    expect(((await (await api('/api/routine-blocks/home')).json()) as { deletedAt: string | null }).deletedAt).toEqual(expect.any(String))

    const restore = await api('/api/routine-blocks/home', { method: 'PUT', json: seededHome })
    expect(restore.status).toBe(200)
    const restored = (await restore.json()) as { routineBlock: unknown; scheduling: Scheduling }
    expect(restored.routineBlock).toMatchObject({ id: 'home', ...seededHome, deletedAt: null })
    const again = restored.scheduling.placements.find((p) => p.taskId === 'ups-return')
    expect(again).toBeDefined()
    expect([1, 4, 5]).toContain(weekdayIn(again!.start))
    expect(restored.scheduling.unscheduled).toEqual([])

    for (const id of ['ups-return', 'desk-work']) expect((await api(`/api/tasks/${id}`, { method: 'DELETE' })).status).toBe(200)
  })

  it('rejects a routine block that ends before it starts, names an unknown context, or has an invalid day', async () => {
    const attempt = async (over: object) =>
      (await api('/api/routine-blocks/bad', { method: 'PUT', json: { ...seededHome, ...over } })).status
    expect(await attempt({ start: '16:00', end: '15:30' })).toBe(400)
    expect(await attempt({ allows: ['moon'] })).toBe(400)
    expect(await attempt({ days: [7] })).toBe(400)
    expect(await attempt({ days: [] })).toBe(400)
    expect(await attempt({ start: '9:00' })).toBe(400)
    expect((await api('/api/routine-blocks/bad')).status).toBe(404)
    expect((await api('/api/routine-blocks/bad', { method: 'DELETE' })).status).toBe(404)
  })

  it('PUT /api/settings validates and stores the routine time zone', async () => {
    expect((await api('/api/settings', { method: 'PUT', json: { timeZone: 'Mars/Olympus' } })).status).toBe(400)
    const res = await api('/api/settings', { method: 'PUT', json: { timeZone: 'America/New_York' } })
    expect(res.status).toBe(200)
    expect(((await res.json()) as { settings: unknown }).settings).toMatchObject({ id: 'default', timeZone: 'America/New_York' })
    expect(((await (await api('/api/sync')).json()) as { settings: { timeZone: string } }).settings.timeZone).toBe('America/New_York')
    // Later tests judge placements against the Pacific routine.
    expect((await api('/api/settings', { method: 'PUT', json: { timeZone: 'America/Los_Angeles' } })).status).toBe(200)
  })
})

describe('seed', () => {
  it('inserts the settings and the routine once and never undoes later edits to them', async () => {
    const fresh = await createTestDb()
    try {
      await seed(fresh.db)
      expect(await fresh.db.select({ id: settings.id, timeZone: settings.timeZone }).from(settings)).toEqual([
        { id: 'default', timeZone: 'America/Los_Angeles' },
      ])
      const blocks = await fresh.db.select().from(routineBlocks).orderBy(routineBlocks.id)
      expect(blocks.map((b) => [b.id, b.days, b.start, b.end, b.allows, b.deletedAt])).toEqual([
        ['home', [1, 4, 5], '09:00', '15:30', ['computer', 'errand', 'home'], null],
        ['office-tue', [2], '10:15', '16:20', ['computer', 'office'], null],
        ['office-wed', [3], '09:00', '16:20', ['computer', 'office'], null],
      ])

      const edited = new Date('2026-11-01T00:00:00Z')
      await fresh.db.update(settings).set({ timeZone: 'America/Denver', updatedAt: edited })
      await fresh.db.update(routineBlocks).set({ end: '15:00', updatedAt: edited }).where(eq(routineBlocks.id, 'home'))
      await fresh.db.update(routineBlocks).set({ deletedAt: edited, updatedAt: edited }).where(eq(routineBlocks.id, 'office-wed'))
      await seed(fresh.db)

      expect(await fresh.db.select({ timeZone: settings.timeZone }).from(settings)).toEqual([{ timeZone: 'America/Denver' }])
      const rows = Object.fromEntries((await fresh.db.select().from(routineBlocks)).map((b) => [b.id, b]))
      expect(rows.home).toMatchObject({ end: '15:00', updatedAt: edited, deletedAt: null })
      expect(rows['office-wed']).toMatchObject({ deletedAt: edited })
    } finally {
      await fresh.close()
    }
  })

  it('creates work and personal once and keeps later edits on a re-seed, while the inbox is reset', async () => {
    const fresh = await createTestDb()
    try {
      await seed(fresh.db)
      const first = await fresh.db.select().from(categories).orderBy(categories.sortOrder)
      expect(first.map((p) => [p.id, p.name, p.area, p.scheduleId, p.deletedAt])).toEqual([
        ['inbox', 'Inbox', null, 'work', null],
        ['work', 'Work', 'work', 'work', null],
        ['personal', 'Personal', 'personal', 'personal', null],
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

describe('calendar event writes', () => {
  const start = new Date(Date.now() + 3 * 86_400_000)
  start.setUTCMinutes(0, 0, 0)
  const end = new Date(start.getTime() + 3_600_000)
  const day = start.toISOString().slice(0, 10)
  const nextDay = new Date(start.getTime() + 86_400_000).toISOString().slice(0, 10)
  const write: EventBody = {
    calendarId: 'cal-rw',
    summary: 'Dentist',
    location: 'Main St',
    description: null,
    startAt: start.toISOString(),
    endAt: end.toISOString(),
    allDay: false,
    responseStatus: null,
  }
  /** The body that matches ev-1's stored state; tests that change ev-1 update it. */
  let ev1 = { ...write }
  let notices = 0
  let unsubscribe = () => {}
  const noScheduling = { placements: [], unscheduled: [], late: [] }

  beforeAll(async () => {
    await db.insert(googleAccounts).values({ id: 'acc-ev', email: 'ev@example.com', label: 'ev', refreshTokenEnc: 'opaque' })
    await db.insert(calendars).values([
      { id: 'cal-rw', accountId: 'acc-ev', googleId: 'ev@example.com', summary: 'Mine', accessRole: 'owner' },
      { id: 'cal-ro', accountId: 'acc-ev', googleId: 'en.usa#holiday@group.v.calendar.google.com', summary: 'Holidays', accessRole: 'reader' },
      { id: 'cal-off', accountId: 'acc-ev', googleId: 'team@group.calendar.google.com', summary: 'Team', accessRole: 'writer', selected: false },
    ])
    fake.eventWrites = []
    unsubscribe = changes.subscribe(() => {
      notices += 1
    })
  })

  afterAll(() => unsubscribe())

  it('PUT with a new id creates the event on Google and stores it under the client id', async () => {
    const before = notices
    const res = await api('/api/events/ev-1', { method: 'PUT', json: write })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { event: Record<string, unknown>; scheduling: unknown }
    expect(body.scheduling).toEqual(noScheduling)
    expect(notices).toBe(before + 1)
    expect(body.event).toMatchObject({
      id: 'ev-1',
      calendarId: 'cal-rw',
      googleId: 'g-1',
      status: 'confirmed',
      summary: 'Dentist',
      location: 'Main St',
      description: null,
      startAt: start.toISOString(),
      endAt: end.toISOString(),
      allDay: false,
      responseStatus: null,
      htmlLink: 'https://www.google.com/calendar/event?eid=g-1',
      attendees: null,
      deletedAt: null,
    })
    expect(fake.eventWrites).toEqual([
      {
        method: 'insert',
        calendarId: 'ev@example.com',
        body: { summary: 'Dentist', location: 'Main St', start: { dateTime: start.toISOString() }, end: { dateTime: end.toISOString() } },
      },
    ])
    // The reply is the row exactly as /api/sync and GET /api/events/:id serialize it.
    const synced = (await (await api('/api/sync')).json()) as { events: { id: string }[] }
    expect(synced.events.find((e) => e.id === 'ev-1')).toEqual(body.event)
    expect(await (await api('/api/events/ev-1')).json()).toEqual(body.event)
  })

  it('keeps the client id when a sync already stored the Google event under its own id', async () => {
    const googleId = `g-${fake.nextGoogleId}`
    await db
      .insert(events)
      .values({ id: 'raced-row', calendarId: 'cal-rw', googleId, status: 'confirmed', allDay: false, startAt: start, endAt: end })
    const res = await api('/api/events/ev-2', { method: 'PUT', json: { ...write, summary: 'Raced' } })
    expect(res.status).toBe(200)
    expect(((await res.json()) as { event: { googleId: string } }).event.googleId).toBe(googleId)
    const rows = await db.select({ id: events.id }).from(events).where(eq(events.googleId, googleId))
    expect(rows).toEqual([{ id: 'ev-2' }])
  })

  it('a UUID id is also the Google id, so a retried create finds the first attempt (409) instead of duplicating it', async () => {
    const id = '6F9619FF-8B86-D011-B42D-00C04FC964FF'
    const googleId = '6f9619ff8b86d011b42d00c04fc964ff'
    fake.eventWrites = []
    const res = await api(`/api/events/${id}`, { method: 'PUT', json: { ...write, summary: 'Retried' } })
    expect(res.status).toBe(200)
    expect(((await res.json()) as { event: { id: string; googleId: string } }).event).toMatchObject({ id, googleId })
    expect(fake.eventWrites).toEqual([expect.objectContaining({ method: 'insert', body: expect.objectContaining({ id: googleId }) })])

    // Google's reply (or the row written from it) was lost: the client retries the same PUT.
    await db.delete(events).where(eq(events.id, id))
    const googleCount = fake.googleEvents.size
    fake.eventWrites = []
    const retry = await api(`/api/events/${id}`, { method: 'PUT', json: { ...write, summary: 'Retried' } })
    expect(retry.status).toBe(200)
    const { event } = (await retry.json()) as { event: { id: string; googleId: string; summary: string } }
    expect(event).toMatchObject({ id, googleId, summary: 'Retried' })
    expect(fake.eventWrites).toEqual([])
    expect(fake.googleEvents.size).toBe(googleCount)
    expect(await db.select({ id: events.id }).from(events).where(eq(events.googleId, googleId))).toEqual([{ id }])
  })

  it("PUT on a live row patches only the changed fields and returns Google's copy", async () => {
    const before = (await (await api('/api/events/ev-1')).json()) as { updatedAt: string }
    fake.eventWrites = []
    ev1 = { ...ev1, summary: 'Dentist (moved)', location: null }
    const res = await api('/api/events/ev-1', { method: 'PUT', json: ev1 })
    expect(res.status).toBe(200)
    const { event } = (await res.json()) as { event: { updatedAt: string } }
    expect(event).toMatchObject({ id: 'ev-1', summary: 'Dentist (moved)', location: null, startAt: start.toISOString(), allDay: false })
    expect(new Date(event.updatedAt).getTime()).toBeGreaterThan(new Date(before.updatedAt).getTime())
    expect(fake.eventWrites).toEqual([
      { method: 'patch', calendarId: 'ev@example.com', googleId: 'g-1', body: { summary: 'Dentist (moved)', location: null } },
    ])
  })

  it('moving a timed event sends start and end as dateTime', async () => {
    fake.eventWrites = []
    const laterStart = new Date(start.getTime() + 86_400_000)
    const laterEnd = new Date(end.getTime() + 86_400_000)
    ev1 = { ...ev1, startAt: laterStart.toISOString(), endAt: laterEnd.toISOString() }
    const res = await api('/api/events/ev-1', { method: 'PUT', json: ev1 })
    expect(res.status).toBe(200)
    expect(((await res.json()) as { event: { startAt: string } }).event.startAt).toBe(laterStart.toISOString())
    expect(fake.eventWrites).toEqual([
      {
        method: 'patch',
        calendarId: 'ev@example.com',
        googleId: 'g-1',
        body: { start: { dateTime: laterStart.toISOString() }, end: { dateTime: laterEnd.toISOString() } },
      },
    ])
  })

  it('turning an event all-day sends dates, clears dateTime, and stores UTC midnight; an identical PUT is a no-op', async () => {
    fake.eventWrites = []
    ev1 = { ...ev1, startAt: `${day}T00:00:00Z`, endAt: `${nextDay}T00:00:00Z`, allDay: true }
    const res = await api('/api/events/ev-1', { method: 'PUT', json: ev1 })
    expect(res.status).toBe(200)
    const { event } = (await res.json()) as { event: unknown }
    expect(event).toMatchObject({ allDay: true, startAt: `${day}T00:00:00.000Z`, endAt: `${nextDay}T00:00:00.000Z` })
    expect(fake.eventWrites).toEqual([
      {
        method: 'patch',
        calendarId: 'ev@example.com',
        googleId: 'g-1',
        body: { start: { date: day, dateTime: null }, end: { date: nextDay, dateTime: null } },
      },
    ])

    fake.eventWrites = []
    const again = await api('/api/events/ev-1', { method: 'PUT', json: ev1 })
    expect(again.status).toBe(200)
    expect(((await again.json()) as { event: unknown }).event).toEqual(event)
    expect(fake.eventWrites).toEqual([])
  })

  it("a changed responseStatus re-sends Google's current attendee list with only the self entry changed", async () => {
    const attendees: GoogleEventAttendee[] = [
      { email: 'lead@example.com', organizer: true, responseStatus: 'accepted' },
      { email: 'ev@example.com', self: true, responseStatus: 'needsAction' },
      // Invited on Google after our last sync: an RSVP built from our stale copy would drop them.
      { email: 'new@example.com', optional: true, responseStatus: 'needsAction' },
    ]
    const meeting: GoogleEvent = {
      id: 'g-invite',
      status: 'confirmed',
      summary: 'Design review',
      start: { dateTime: start.toISOString() },
      end: { dateTime: end.toISOString() },
      organizer: { email: 'lead@example.com' },
      attendees,
    }
    fake.googleEvents.set('g-invite', meeting)
    await db.insert(events).values({ id: 'ev-invite', ...mapEvent('cal-rw', { ...meeting, attendees: attendees.slice(0, 2) }) })
    fake.eventWrites = []
    const invite = { ...write, summary: 'Design review', location: null, responseStatus: 'accepted' }

    const res = await api('/api/events/ev-invite', { method: 'PUT', json: invite })
    expect(res.status).toBe(200)
    expect(fake.eventWrites).toEqual([
      {
        method: 'patch',
        calendarId: 'ev@example.com',
        googleId: 'g-invite',
        body: {
          attendees: [
            { email: 'lead@example.com', organizer: true, responseStatus: 'accepted' },
            { email: 'ev@example.com', self: true, responseStatus: 'accepted' },
            { email: 'new@example.com', optional: true, responseStatus: 'needsAction' },
          ],
        },
      },
    ])
    const { event } = (await res.json()) as { event: { responseStatus: string; attendees: { email: string; responseStatus: string }[] } }
    expect(event.responseStatus).toBe('accepted')
    expect(event.attendees.map((a) => [a.email, a.responseStatus])).toEqual([
      ['lead@example.com', 'accepted'],
      ['ev@example.com', 'accepted'],
      ['new@example.com', 'needsAction'],
    ])

    // The same answer again changes nothing, so Google is not called.
    fake.eventWrites = []
    expect((await api('/api/events/ev-invite', { method: 'PUT', json: invite })).status).toBe(200)
    expect(fake.eventWrites).toEqual([])

    // An event the account is not a guest of cannot be answered.
    const solo = await api('/api/events/ev-1', { method: 'PUT', json: { ...ev1, responseStatus: 'declined' } })
    expect(solo.status).toBe(400)
    expect(await solo.json()).toEqual({ error: expect.stringContaining('not a guest') })
    expect(fake.eventWrites).toEqual([])
  })

  it("an answer Google already holds (given from another device) is not re-sent; Google's copy is stored", async () => {
    const meeting: GoogleEvent = {
      id: 'g-answered',
      status: 'confirmed',
      summary: 'Standup',
      start: { dateTime: start.toISOString() },
      end: { dateTime: end.toISOString() },
      attendees: [
        { email: 'lead@example.com', organizer: true, responseStatus: 'accepted' },
        { email: 'ev@example.com', self: true, responseStatus: 'declined' },
      ],
    }
    fake.googleEvents.set('g-answered', meeting)
    // Our row, and the client's, predate the answer.
    const stale = { ...meeting, attendees: [{ email: 'ev@example.com', self: true, responseStatus: 'needsAction' }] }
    await db.insert(events).values({ id: 'ev-answered', ...mapEvent('cal-rw', stale) })
    fake.eventWrites = []

    const body = { ...write, summary: 'Standup', location: null, responseStatus: 'declined' }
    const res = await api('/api/events/ev-answered', { method: 'PUT', json: body })
    expect(res.status).toBe(200)
    expect(fake.eventWrites).toEqual([])
    const { event } = (await res.json()) as { event: { responseStatus: string; attendees: unknown[] } }
    expect(event.responseStatus).toBe('declined')
    expect(event.attendees).toHaveLength(2)
    const stored = (await (await api('/api/events/ev-answered')).json()) as { responseStatus: string }
    expect(stored.responseStatus).toBe('declined')
  })

  it('rejects bad bodies (400), unsynced or read-only calendars (403), and moves between calendars (400)', async () => {
    fake.eventWrites = []
    const backwards = await api('/api/events/ev-bad', { method: 'PUT', json: { ...write, endAt: write.startAt } })
    expect(backwards.status).toBe(400)
    expect(((await backwards.json()) as { error: string }).error).toBe('validation failed')
    const sameDay = await api('/api/events/ev-bad', {
      method: 'PUT',
      json: { ...write, startAt: `${day}T00:00:00Z`, endAt: `${day}T12:00:00Z`, allDay: true },
    })
    expect(sameDay.status).toBe(400)
    // All-day instants are UTC midnights (the apps convert local days with `AllDayDate.storedInstant`).
    const localMidnight = await api('/api/events/ev-bad', {
      method: 'PUT',
      json: { ...write, startAt: `${day}T08:00:00Z`, endAt: `${nextDay}T08:00:00Z`, allDay: true },
    })
    expect(localMidnight.status).toBe(400)
    expect(await localMidnight.json()).toEqual({
      error: 'validation failed',
      issues: [expect.objectContaining({ path: ['startAt'], message: expect.stringContaining('UTC midnight') })],
    })
    expect((await api('/api/events/ev-bad', { method: 'PUT', json: { ...write, responseStatus: 'maybe' } })).status).toBe(400)
    expect((await api('/api/events/ev-bad', { method: 'PUT', json: { ...write, startAt: 'tomorrow' } })).status).toBe(400)

    const unknown = await api('/api/events/ev-bad', { method: 'PUT', json: { ...write, calendarId: 'nope' } })
    expect(unknown.status).toBe(400)
    expect(await unknown.json()).toEqual({ error: 'unknown calendarId nope' })
    const readOnly = await api('/api/events/ev-bad', { method: 'PUT', json: { ...write, calendarId: 'cal-ro' } })
    expect(readOnly.status).toBe(403)
    expect(await readOnly.json()).toEqual({ error: expect.stringContaining('read-only') })
    const unsynced = await api('/api/events/ev-bad', { method: 'PUT', json: { ...write, calendarId: 'cal-off' } })
    expect(unsynced.status).toBe(403)
    expect(await unsynced.json()).toEqual({ error: expect.stringContaining('not synced') })

    const moved = await api('/api/events/ev-2', { method: 'PUT', json: { ...write, summary: 'Raced', calendarId: 'cal-ro' } })
    expect(moved.status).toBe(400)
    expect(await moved.json()).toEqual({ error: expect.stringContaining('another calendar') })

    expect(fake.eventWrites).toEqual([])
    const missing = await api('/api/events/ev-bad')
    expect(missing.status).toBe(404)
    expect(await missing.json()).toEqual({ error: 'event ev-bad not found' })
  })

  it("passes Google's 400 and 403 through with its message and leaves the row alone; other failures are 502", async () => {
    const before = await (await api('/api/events/ev-2')).json()
    const edit = { ...write, summary: 'Raced again' }
    fake.nextWriteError = new GoogleApiError(400, JSON.stringify({ error: { code: 400, message: 'Invalid start time.' } }))
    const invalid = await api('/api/events/ev-2', { method: 'PUT', json: edit })
    expect(invalid.status).toBe(400)
    expect(await invalid.json()).toEqual({ error: 'Google API responded 400: Invalid start time.' })
    expect(await (await api('/api/events/ev-2')).json()).toEqual(before)

    // Editing a meeting someone else organises: Google refuses, and the client drops its edit.
    fake.nextWriteError = new GoogleApiError(403, JSON.stringify({ error: { message: 'Forbidden' } }))
    const theirs = await api('/api/events/ev-2', { method: 'PUT', json: edit })
    expect(theirs.status).toBe(403)
    expect(await theirs.json()).toEqual({ error: 'Google API responded 403: Forbidden' })
    expect(await (await api('/api/events/ev-2')).json()).toEqual(before)

    // A failed create stores nothing.
    fake.nextWriteError = new GoogleApiError(403, JSON.stringify({ error: { message: 'Forbidden' } }))
    const create = await api('/api/events/ev-never', { method: 'PUT', json: write })
    expect(create.status).toBe(403)
    expect(await create.json()).toEqual({ error: 'Google API responded 403: Forbidden' })
    expect((await api('/api/events/ev-never')).status).toBe(404)

    // Quota, outages and a dead refresh token are the server's to sort out: the client keeps the write.
    for (const err of [
      new GoogleApiError(429, JSON.stringify({ error: { message: 'Rate Limit Exceeded' } })),
      new GoogleApiError(503, '<html>unavailable</html>'),
      new GoogleTokenError(400, JSON.stringify({ error: 'invalid_grant' })),
    ]) {
      fake.nextWriteError = err
      const res = await api('/api/events/ev-2', { method: 'PUT', json: edit })
      expect(res.status).toBe(502)
      expect(await res.json()).toEqual({ error: err.message })
    }
    expect(await (await api('/api/events/ev-2')).json()).toEqual(before)
  })

  it('an event Google deleted since the last sync is tombstoned when an edit or RSVP meets a 404 or 410', async () => {
    const gone: GoogleEvent = {
      id: 'g-gone',
      status: 'confirmed',
      summary: 'Offsite',
      start: { dateTime: start.toISOString() },
      end: { dateTime: end.toISOString() },
      attendees: [{ email: 'ev@example.com', self: true, responseStatus: 'needsAction' }],
    }
    // One row per way Google can answer; none of them exists on the fake's Google any more.
    const ids = ['ev-gone-404', 'ev-gone-410', 'ev-gone-rsvp']
    for (const id of ids) await db.insert(events).values({ id, ...mapEvent('cal-rw', { ...gone, id: `g-${id}` }) })
    const body = { ...write, summary: 'Offsite', location: null }
    const cursor = ((await (await api('/api/sync')).json()) as { cursor: string }).cursor
    const expectTombstoned = async (id: string, res: Response) => {
      expect(res.status).toBe(404)
      expect(await res.json()).toEqual({ error: `event ${id} not found` })
      const row = (await (await api(`/api/events/${id}`)).json()) as { deletedAt: string | null }
      expect(row.deletedAt).toEqual(expect.any(String))
    }

    const before = notices
    fake.nextWriteError = new GoogleApiError(404, JSON.stringify({ error: { message: 'Not Found' } }))
    await expectTombstoned('ev-gone-404', await api('/api/events/ev-gone-404', { method: 'PUT', json: { ...body, summary: 'Moved' } }))
    expect(notices).toBe(before + 1)

    fake.nextWriteError = new GoogleGoneError(JSON.stringify({ error: { message: 'Resource has been deleted' } }))
    await expectTombstoned('ev-gone-410', await api('/api/events/ev-gone-410', { method: 'PUT', json: { ...body, summary: 'Moved' } }))

    // An RSVP looks the live attendee list up first; the fake's Google has no such event.
    const rsvp = await api('/api/events/ev-gone-rsvp', { method: 'PUT', json: { ...body, responseStatus: 'accepted' } })
    await expectTombstoned('ev-gone-rsvp', rsvp)

    expect(fake.eventWrites.filter((w) => w.method === 'patch' && ids.some((id) => w.googleId === `g-${id}`))).toEqual([])
    const synced = (await (await api(`/api/sync?since=${encodeURIComponent(cursor)}`)).json()) as { events: { id: string }[] }
    expect(synced.events.map((e) => e.id).sort()).toEqual(ids)
  })

  it('DELETE removes the event on Google, tombstones the row and reschedules', async () => {
    const cursor = ((await (await api('/api/sync')).json()) as { cursor: string }).cursor
    fake.eventWrites = []
    const before = notices
    const res = await api('/api/events/ev-2', { method: 'DELETE' })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ scheduling: noScheduling })
    expect(notices).toBe(before + 1)
    expect(fake.eventWrites).toEqual([{ method: 'delete', calendarId: 'ev@example.com', googleId: 'g-2' }])
    expect(fake.googleEvents.has('g-2')).toBe(false)

    const synced = (await (await api(`/api/sync?since=${encodeURIComponent(cursor)}`)).json()) as {
      events: { id: string; deletedAt: string | null }[]
    }
    expect(synced.events).toEqual([expect.objectContaining({ id: 'ev-2', deletedAt: expect.any(String) })])

    // The tombstone reads back like a task tombstone, rejects writes, and deleting it again is a local no-op.
    const tombstone = await api('/api/events/ev-2')
    expect(tombstone.status).toBe(200)
    expect(((await tombstone.json()) as { deletedAt: string | null }).deletedAt).toEqual(expect.any(String))
    const put = await api('/api/events/ev-2', { method: 'PUT', json: { ...write, summary: 'Raced' } })
    expect(put.status).toBe(404)
    expect(await put.json()).toEqual({ error: 'event ev-2 not found' })
    fake.eventWrites = []
    expect((await api('/api/events/ev-2', { method: 'DELETE' })).status).toBe(200)
    expect(fake.eventWrites).toEqual([])

    const never = await api('/api/events/never-existed', { method: 'DELETE' })
    expect(never.status).toBe(404)
    expect(await never.json()).toEqual({ error: 'event never-existed not found' })

    // When Google refuses, the row stays live; the client's refetch of it undoes the local delete.
    fake.nextWriteError = new GoogleApiError(403, JSON.stringify({ error: { message: 'Forbidden' } }))
    expect((await api('/api/events/ev-1', { method: 'DELETE' })).status).toBe(403)
    expect(((await (await api('/api/events/ev-1')).json()) as { deletedAt: string | null }).deletedAt).toBeNull()
  })
})
