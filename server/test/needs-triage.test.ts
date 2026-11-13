import { setTimeout as sleep } from 'node:timers/promises'
import type { Hono } from 'hono'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { createApp } from '../src/app.js'
import type { Db } from '../src/db/client.js'
import { runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { upsertTask } from '../src/tasks.js'
import { createTestDb } from './db.js'
import { FakeSync, testConfig as config } from './fixtures.js'

const NOW = new Date('2026-11-09T16:00:00Z')
const body = { categoryId: 'work', title: 'Triage fixture', durationMinutes: 30, priority: 'medium', deadlineType: 'none' } as const
interface WireTask {
  id: string
  categoryId: string
  dueAt: string | null
  startAt: string | null
  pinnedStart: string | null
  someday: boolean
  deadlineType: 'none' | 'soft' | 'hard'
  updatedAt: string
  deletedAt: string | null
}

let db: Db
let close: () => Promise<void>
let app: Hono

beforeAll(async () => {
  ;({ db, close } = await createTestDb())
  await seed(db)
  app = createApp({ db, config, sync: new FakeSync(), reschedule: () => runScheduling(db, config, NOW) })
})
afterAll(() => close())

async function request(path: string, method = 'GET', json?: unknown) {
  return app.request(path, {
    method,
    headers: { authorization: `Bearer ${config.API_TOKEN}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
    ...(json === undefined ? {} : { body: JSON.stringify(json) }),
  })
}

async function write(id: string, method: 'PUT' | 'PATCH', json: unknown): Promise<WireTask> {
  const response = await request(`/api/tasks/${id}`, method, json)
  expect(response.status).toBe(200)
  return ((await response.json()) as { task: WireTask }).task
}

async function tool(name: string, args: Record<string, unknown>) {
  const response = await request('/mcp', 'POST', { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } })
  expect(response.status).toBe(200)
  return (await response.json()) as { result: { isError?: boolean; structuredContent?: { task: WireTask; tasks: WireTask[] } } }
}

describe('Someday across REST and sync', () => {
  it('defaults only new tasks to false, preserves omitted old-client writes, and accepts explicit true/false', async () => {
    expect(await write('triage-default', 'PUT', body)).toMatchObject({ dueAt: null, someday: false })
    const initial = await upsertTask(db, 'triage-keep', { ...body, someday: true }, NOW)
    const replaced = await write(initial.id, 'PUT', { ...body, title: 'Old client edit' })
    expect(replaced.someday).toBe(true)
    expect(new Date(replaced.updatedAt).getTime()).toBeGreaterThan(initial.updatedAt.getTime())
    expect((await write(initial.id, 'PATCH', { notes: 'Unrelated edit' })).someday).toBe(true)
    expect((await write(initial.id, 'PATCH', { someday: false })).someday).toBe(false)
    expect((await write(initial.id, 'PUT', { ...body, someday: true, dueAt: '2026-11-10T19:00:00Z' })).someday).toBe(true)
    expect(await write(initial.id, 'PATCH', { dueAt: null })).toMatchObject({ dueAt: null, someday: true })
    expect((await request(`/api/tasks/${initial.id}`, 'DELETE')).status).toBe(200)
    expect(await write(initial.id, 'PUT', body)).toMatchObject({ someday: true, deletedAt: null })
  })

  it('keeps valid start plus Someday through legacy snapshots and clears due dates and pins when enabled', async () => {
    const dates = { dueAt: '2026-11-10T19:00:00.000Z', startAt: '2026-11-10T17:00:00.000Z', pinnedStart: '2026-11-10T18:00:00.000Z' }
    await write('someday-start', 'PUT', { ...body, ...dates, deadlineType: 'hard' })
    const enabled = await write('someday-start', 'PATCH', { someday: true })
    expect(enabled).toMatchObject({ someday: true, deadlineType: 'none', dueAt: null, pinnedStart: null, startAt: dates.startAt })
    const { someday, ...legacy } = enabled
    expect(await write(enabled.id, 'PUT', { ...legacy, title: 'Legacy rename' })).toMatchObject({ someday: true, startAt: dates.startAt })
    expect(await write(enabled.id, 'PATCH', { notes: 'Unrelated' })).toMatchObject({ someday: true, startAt: dates.startAt })
    expect(await write(enabled.id, 'PATCH', { startAt: dates.startAt })).toMatchObject({ someday: true, startAt: dates.startAt })
    for (const field of ['dueAt', 'startAt', 'pinnedStart'] as const) {
      await write(enabled.id, 'PATCH', { someday: true })
      expect(await write(enabled.id, 'PATCH', { [field]: '2026-11-11T19:00:00Z' })).toMatchObject({ someday: false })
    }
    expect(await write(enabled.id, 'PATCH', { someday: true })).toMatchObject({ someday: true, dueAt: null, pinnedStart: null, startAt: '2026-11-11T19:00:00.000Z' })
    const current = await (await request(`/api/tasks/${enabled.id}`)).json() as WireTask
    const { someday: ignored, ...oldClient } = current
    expect(await write(enabled.id, 'PUT', { ...oldClient, startAt: null })).toMatchObject({ someday: true, startAt: null })
  })

  it('normalizes conflicting explicit Someday creates and identical PUT retries without restoring due dates or pins', async () => {
    const input = { ...body, deadlineType: 'soft', someday: true, dueAt: '2026-11-10T19:00:00Z', pinnedStart: '2026-11-10T18:00:00Z', startAt: '2026-11-10T17:00:00Z' }
    for (let i = 0; i < 2; i++) {
      expect(await write('someday-retry', 'PUT', input)).toMatchObject({ someday: true, deadlineType: 'none', dueAt: null, pinnedStart: null, startAt: '2026-11-10T17:00:00.000Z' })
    }
  })

  it('rejects null and non-booleans on both write routes without altering the row', async () => {
    await write('triage-invalid', 'PUT', { ...body, someday: true })
    for (const value of [null, 'true', 1, {}, []]) {
      for (const method of ['PUT', 'PATCH']) {
        const json = method === 'PUT' ? { ...body, someday: value } : { someday: value }
        expect((await request('/api/tasks/triage-invalid', method, json)).status).toBe(400)
      }
    }
    expect(await (await request('/api/tasks/triage-invalid')).json()).toMatchObject({ someday: true })
  })

  it('exposes both decisions through GET, full sync, incremental sync, and tombstones', async () => {
    await write('triage-sync', 'PUT', body)
    const full = await (await request('/api/sync')).json() as { cursor: string; tasks: WireTask[] }
    expect(full.tasks.find((task) => task.id === 'triage-sync')?.someday).toBe(false)
    await sleep(5)
    const changed = await write('triage-sync', 'PATCH', { someday: true })
    const delta = await (await request(`/api/sync?since=${full.cursor}`)).json() as { tasks: WireTask[] }
    expect(delta.tasks).toContainEqual(changed)
    expect(await (await request('/api/tasks/triage-sync')).json()).toEqual(changed)
    expect((await request('/api/tasks/triage-sync', 'DELETE')).status).toBe(200)
    const deleted = await (await request(`/api/sync?since=${full.cursor}`)).json() as { tasks: WireTask[] }
    expect(deleted.tasks.find((task) => task.id === 'triage-sync')).toMatchObject({ someday: true, deletedAt: expect.any(String) })
  })
})

describe('MCP triage writes and category views', () => {
  it('accepts the field, preserves omission, rejects invalid values, and returns it from task tools', async () => {
    const created = await tool('create_task', { ...body, id: 'triage-mcp', someday: true })
    expect(created.result.isError).not.toBe(true)
    expect(created.result.structuredContent?.task.someday).toBe(true)
    expect((await tool('update_task', { id: 'triage-mcp', title: 'MCP edited' })).result.structuredContent?.task.someday).toBe(true)
    expect((await tool('update_task', { id: 'triage-mcp', pinnedStart: '2026-11-10T18:00:00Z' })).result.structuredContent?.task).toMatchObject({ someday: false, pinnedStart: '2026-11-10T18:00:00.000Z' })
    expect((await tool('update_task', { id: 'triage-mcp', someday: true })).result.structuredContent?.task).toMatchObject({ someday: true, dueAt: null, pinnedStart: null })
    expect((await tool('update_task', { id: 'triage-mcp', someday: false })).result.structuredContent?.task.someday).toBe(false)
    for (const value of [null, 'false', 0]) {
      expect((await tool('create_task', { ...body, id: 'triage-mcp-invalid', someday: value })).result.isError).toBe(true)
      expect((await tool('update_task', { id: 'triage-mcp', someday: value })).result.isError).toBe(true)
    }
    expect((await tool('get_task', { id: 'triage-mcp' })).result.structuredContent?.task.someday).toBe(false)
    expect((await tool('complete_task', { id: 'triage-mcp' })).result.structuredContent?.task.someday).toBe(false)
    expect((await tool('create_task', { ...body, id: 'triage-mcp-default' })).result.structuredContent?.task.someday).toBe(false)
  })

  it('includes categorized undated undecided tasks only in Inbox while keeping the real category', async () => {
    await write('view-pending', 'PUT', body)
    await write('view-decided', 'PUT', { ...body, someday: true })
    await write('view-dated', 'PUT', { ...body, dueAt: '2026-11-10T19:00:00Z' })
    await write('view-started', 'PUT', { ...body, startAt: '2026-11-10T19:00:00Z' })
    await write('view-pinned', 'PUT', { ...body, pinnedStart: '2026-11-10T19:00:00Z' })
    await write('view-both', 'PUT', { ...body, dueAt: '2026-11-10T19:00:00Z', someday: true })
    await write('view-deadline-only', 'PUT', { ...body, deadlineType: 'hard' })
    await write('view-unfiled', 'PUT', { ...body, categoryId: 'inbox', someday: true, dueAt: '2026-11-10T19:00:00Z' })
    await write('view-completed', 'PUT', { ...body, completedAt: NOW.toISOString() })
    await write('view-deleted', 'PUT', body)
    await request('/api/tasks/view-deleted', 'DELETE')
    const list = async (categoryId?: string, includeCompleted = false) => {
      const result = await tool('list_tasks', { ...(categoryId === undefined ? {} : { categoryId }), includeCompleted, limit: 200 })
      expect(result.result.isError).not.toBe(true)
      return result.result.structuredContent!.tasks.filter((task) => task.id.startsWith('view-'))
    }
    const inbox = await list('inbox')
    expect(inbox.map((task) => task.id).sort()).toEqual(['view-deadline-only', 'view-pending', 'view-unfiled'])
    expect(inbox.find((task) => task.id === 'view-pending')?.categoryId).toBe('work')
    expect((await list('work')).map((task) => task.id).sort()).toEqual(['view-both', 'view-dated', 'view-decided', 'view-pinned', 'view-started'])
    expect((await list()).map((task) => task.id).sort()).toEqual(['view-both', 'view-dated', 'view-deadline-only', 'view-decided', 'view-pending', 'view-pinned', 'view-started', 'view-unfiled'])
    expect((await list('inbox', true)).map((task) => task.id)).toContain('view-completed')
    await write('view-pending', 'PATCH', { someday: true })
    expect((await list('inbox')).map((task) => task.id)).not.toContain('view-pending')
    expect((await list('work')).map((task) => task.id)).toContain('view-pending')
  })
})
