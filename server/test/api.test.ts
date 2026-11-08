import { setTimeout as sleep } from 'node:timers/promises'
import { localParts, weekdayOf } from '@florida/scheduler'
import type { Hono } from 'hono'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { createApp } from '../src/app.js'
import { ChangeBus } from '../src/changes.js'
import type { Config } from '../src/config.js'
import type { Db } from '../src/db/client.js'
import { calendars, googleAccounts } from '../src/db/schema.js'
import type { CalendarRow, GoogleAccountRow } from '../src/db/schema.js'
import type { CalendarSyncService } from '../src/google/sync.js'
import { runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'

const config: Config = {
  DATABASE_URL: 'postgres://unused',
  API_TOKEN: 'test-token-0123456789abcdef',
  TOKEN_ENCRYPTION_KEY: '00'.repeat(32),
  GOOGLE_CLIENT_ID: 'client-id',
  GOOGLE_CLIENT_SECRET: 'client-secret',
  PUBLIC_URL: 'https://florida.test',
  PORT: 8080,
  HORIZON_DAYS: 28,
}

class FakeSync implements CalendarSyncService {
  syncCalendarCalls: CalendarRow[] = []
  syncAllCalls = 0
  async connectAccount(): Promise<GoogleAccountRow> {
    throw new Error('not used in tests')
  }
  async syncCalendar(calendar: CalendarRow): Promise<void> {
    this.syncCalendarCalls.push(calendar)
  }
  async syncAll(): Promise<void> {
    this.syncAllCalls += 1
  }
  async ensureAllWatches(): Promise<void> {}
}

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
  projectId: 'inbox',
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

  it('returns 400 for an unknown project', async () => {
    const res = await api('/api/tasks/bad', { method: 'PUT', json: { ...taskBody, projectId: 'nope' } })
    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({ error: 'unknown projectId nope' })
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
      projects: { id: string }[]
      tasks: { id: string; deletedAt: string | null }[]
      events: unknown[]
      placements: { taskId: string }[]
      accounts: unknown[]
      calendars: unknown[]
    }
    expect(new Date(body.cursor).toISOString()).toBe(body.cursor)
    expect(body.schedules.map((s) => s.id).sort()).toEqual(['personal', 'work'])
    expect(body.projects.map((p) => p.id)).toEqual(['inbox'])
    expect(body.tasks).toEqual([expect.objectContaining({ id: 't1', deletedAt: null })])
    expect(body.events).toEqual([])
    expect(body.placements.map((p) => p.taskId)).toEqual(['t1'])
    expect(body.accounts).toEqual([])
    expect(body.calendars).toEqual([])
    cursorAfterCreate = body.cursor
  })

  it('GET /api/sync?since=cursor returns no changed rows but the full placements table', async () => {
    const res = await api(`/api/sync?since=${encodeURIComponent(cursorAfterCreate)}`)
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, unknown[]>
    expect(body.schedules).toEqual([])
    expect(body.projects).toEqual([])
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

  it('upserts schedules and projects, and tombstones schedules', async () => {
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

    const proj = await api('/api/projects/side', { method: 'PUT', json: { name: 'Side', scheduleId: 'deep', color: '#ff0' } })
    expect(proj.status).toBe(200)
    const projBody = (await proj.json()) as { project: { scheduleId: string; sortOrder: number } }
    expect(projBody.project).toMatchObject({ scheduleId: 'deep', sortOrder: 0 })

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

  it('toggles calendar selection', async () => {
    const res = await api('/api/calendars/cal-1', { method: 'PATCH', json: { selected: false } })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { calendar: { id: string; selected: boolean }; scheduling: unknown }
    expect(body.calendar).toEqual({ id: 'cal-1', googleId: 'me@example.com', selected: false })
    expect((await api('/api/calendars/nope', { method: 'PATCH', json: { selected: true } })).status).toBe(404)
  })

  it('POST /api/google/sync syncs everything then reschedules', async () => {
    const res = await api('/api/google/sync', { method: 'POST' })
    expect(res.status).toBe(200)
    expect(fake.syncAllCalls).toBe(1)
    expect(await res.json()).toEqual({ placements: [], unscheduled: [], late: [] })
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
