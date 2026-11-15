import { randomUUID } from 'node:crypto'
import { eq } from 'drizzle-orm'
import { Hono } from 'hono'
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import type { Db } from '../src/db/client.js'
import * as schema from '../src/db/schema.js'
import { mountMcp } from '../src/mcp.js'
import { runScheduling } from '../src/scheduling.js'
import * as schedulingModule from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'
import { createApp } from '../src/app.js'
import { FakeSync, testConfig } from './fixtures.js'

let db: Db
let close: () => Promise<void>
let app: Hono
let notices = 0
const now = new Date('2026-11-09T17:00:00Z')
const config = { HORIZON_DAYS: 14 }

beforeAll(async () => {
  vi.setSystemTime(now)
  ;({ db, close } = await createTestDb())
  await seed(db)
  await db.delete(schema.routineBlocks)
  await db.insert(schema.routineBlocks).values({ id: 'work', name: 'Work', days: [1, 2, 3, 4, 5], start: '09:00', end: '17:00', allows: ['computer'] })
  app = new Hono()
  mountMcp(app, { db, horizonDays: config.HORIZON_DAYS, publish: () => { notices++ }, reschedule: async (reason) => {
    const result = await runScheduling(db, config, now, reason)
    notices++
    return result
  } })
})

afterAll(async () => { await close(); vi.useRealTimers() })

async function call(name: string, args: Record<string, unknown>) {
  const response = await app.request('/mcp', { method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }) })
  const body = await response.json() as { result: { isError?: boolean; structuredContent: Record<string, any> }; error?: unknown }
  expect(body.error).toBeUndefined()
  return body.result
}

async function data(name: string, args: Record<string, unknown>) {
  const result = await call(name, args)
  expect(result.isError).toBeFalsy()
  return result.structuredContent
}

async function snapshot() {
  return Promise.all(Object.values(schema).map(async (table) => (await db.select().from(table)).map((row) => JSON.stringify(row)).sort()))
}

describe('MCP write previews and batches', () => {
  it('previews recurring creation with placements without changing any table or notifying', async () => {
    const before = await snapshot()
    const count = notices
    const id = randomUUID()
    const out = await data('create_task', { id, categoryId: 'inbox', title: 'Preview recurring', dryRun: true,
      recurrence: { frequency: 'day', interval: 1, timeZone: 'America/Los_Angeles', startDate: '2026-11-09' },
    })
    expect(out.dryRun).toBe(true)
    expect(out.task.placements.length).toBeGreaterThan(0)
    expect(out.scheduling.placements.some((p: { taskId: string }) => p.taskId !== id)).toBe(true)
    expect(out.changes.some((p: { taskId: string }) => p.taskId === id)).toBe(true)
    expect(await snapshot()).toEqual(before)
    expect(notices).toBe(count)
  })

  it('creates and updates atomically with one scheduling notification per batch', async () => {
    const ids = [randomUUID(), randomUUID()]
    const count = notices
    const scheduler = vi.spyOn(schedulingModule, 'runScheduling')
    const out = await data('batch_create_tasks', { tasks: ids.map((id) => ({ id, categoryId: 'inbox', title: id })) })
    expect(out.results.map((r: { task: { id: string } }) => r.task.id)).toEqual(ids)
    expect(out.results[0].task.placements.length).toBeGreaterThan(0)
    expect(notices).toBe(count + 1)
    expect(scheduler).toHaveBeenCalledTimes(1)
    const updated = await data('batch_update_tasks', { tasks: ids.map((id) => ({ id, priority: 'high' })) })
    expect(updated.results.map((r: { task: { priority: string } }) => r.task.priority)).toEqual(['high', 'high'])
    expect(notices).toBe(count + 2)
    expect(scheduler).toHaveBeenCalledTimes(2)
    const before = await snapshot()
    const failure = await call('batch_update_tasks', { tasks: [{ id: ids[0], title: 'Should roll back' }, { id: 'missing', priority: 'low' }] })
    expect(failure.isError).toBe(true)
    expect(await snapshot()).toEqual(before)
    scheduler.mockRestore()
    expect(notices).toBe(count + 2)
    const failedCreate = await call('batch_create_tasks', { tasks: [{ categoryId: 'inbox', title: 'Rollback create' }, { categoryId: 'missing', title: 'Invalid category' }] })
    expect(failedCreate.isError).toBe(true)
    expect(await snapshot()).toEqual(before)
  })

  it('previews task, day and project changes with complete rollback, including a mixed batch', async () => {
    const project = await data('create_project', { name: 'Preview project', weeklyMinutes: 60 })
    const created = await data('create_task', { categoryId: 'inbox', title: 'Existing', projectId: project.project.id })
    const before = await snapshot()
    const count = notices
    for (const [tool, args] of [
      ['update_task', { id: created.task.id, durationMinutes: 90 }],
      ['set_day', { date: '2026-11-09', kind: 'off' }],
      ['update_project', { id: project.project.id, status: 'on_hold' }],
    ] as const) {
      expect((await data(tool, { ...args, dryRun: true })).dryRun).toBe(true)
      expect(await snapshot()).toEqual(before)
    }
    const mixed = await data('batch', { dryRun: true, operations: [
      { tool: 'update_task', arguments: { id: created.task.id, title: 'Changed' } },
      { tool: 'set_day', arguments: { date: '2026-11-10', kind: 'off' } },
      { tool: 'update_project', arguments: { id: project.project.id, status: 'on_hold' } },
    ] })
    expect(mixed.results).toHaveLength(3)
    expect(await snapshot()).toEqual(before)
    expect(notices).toBe(count)
    const done = await data('batch', { operations: [
      { tool: 'update_task', arguments: { id: created.task.id, title: 'Changed' } },
      { tool: 'complete_task', arguments: { id: created.task.id } },
    ] })
    expect(done.results[1].task.completedAt).not.toBeNull()
    expect(notices).toBe(count + 1)
    expect((await call('create_task', { categoryId: 'missing', title: 'Bad preview', dryRun: true })).isError).toBe(true)
    expect((await call('batch', { operations: [] })).isError).toBe(true)
    expect((await call('batch', { operations: [{ tool: 'upsert_event', arguments: {} }] })).isError).toBe(true)
  })

  it('journals only changed placements and pages equal timestamps without gaps', async () => {
    const rows = await db.select().from(schema.scheduleChanges)
    expect(rows.some((r) => r.reason === 'rescheduled due to task update')).toBe(true)
    const before = rows.length
    await runScheduling(db, config, now)
    expect(await db.select().from(schema.scheduleChanges)).toHaveLength(before)
    const at = new Date('2025-01-01T00:00:00Z')
    await db.update(schema.scheduleChanges).set({ updatedAt: at })
    await db.insert(schema.scheduleChanges).values(['a', 'b', 'c'].map((id) => ({ id, taskId: 'historical', before: [], after: [], reason: 'scheduler replan', changeType: 'moved' as const, updatedAt: at })))
    const seen: string[] = []
    let cursor: unknown
    let out
    do {
      out = await data('list_changes', { since: '2024-12-31T00:00:00Z', limit: 2, ...(cursor === undefined ? {} : { cursor }) })
      seen.push(...out.placements.map((r: { id: string }) => r.id))
      cursor = out.nextCursor
    } while (out.hasMore)
    expect(new Set(seen).size).toBe(seen.length)
    expect(seen).toEqual(expect.arrayContaining(['a', 'b', 'c']))
    expect(seen).toHaveLength(before + 3)
    expect((await data('list_changes', { since: out.since })).placements).toEqual([])
  })

  it('rolls back mutations if scheduling itself fails', async () => {
    const before = await snapshot()
    const count = notices
    const scheduler = vi.spyOn(schedulingModule, 'runScheduling').mockRejectedValueOnce(new Error('scheduler failure'))
    try {
      expect((await call('batch_create_tasks', { tasks: [{ id: randomUUID(), categoryId: 'inbox', title: 'Must roll back' }] })).isError).toBe(true)
      expect(await snapshot()).toEqual(before)
      expect(notices).toBe(count)
    } finally { scheduler.mockRestore() }
  })

  it('reports only newly late and newly unscheduled tasks in previews', async () => {
    const { task: existing } = await data('create_task', { categoryId: 'inbox', title: 'Already impossible', durationMinutes: 99999 })
    const id = randomUUID()
    const out = await data('create_task', { id, categoryId: 'inbox', title: 'New impossible', durationMinutes: 99999, dryRun: true })
    expect(out.newlyUnscheduled.map((item: { taskId: string }) => item.taskId)).toContain(id)
    expect(out.newlyUnscheduled.map((item: { taskId: string }) => item.taskId)).not.toContain(existing.id)
    const { task: alreadyLate } = await data('create_task', { categoryId: 'inbox', title: 'Already late', durationMinutes: 30, dueAt: '2026-11-09T16:00:00Z' })
    const late = await data('create_task', { categoryId: 'inbox', title: 'Late preview', durationMinutes: 30, dueAt: '2026-11-09T16:00:00Z', dryRun: true })
    expect(late.newlyLate.map((item: { taskId: string }) => item.taskId)).toContain(late.task.id)
    expect(late.newlyLate.map((item: { taskId: string }) => item.taskId)).not.toContain(alreadyLate.id)
    const { task: pinned } = await data('create_task', { categoryId: 'inbox', title: 'Pinned is not a late warning', dueAt: '2026-11-09T16:00:00Z', pinnedStart: '2026-11-10T17:00:00Z' })
    const unpinned = await data('update_task', { id: pinned.id, pinnedStart: null, dryRun: true })
    expect(unpinned.newlyLate.map((item: { taskId: string }) => item.taskId)).toContain(pinned.id)
  })

  it('includes task/project changes and journals unscheduled-only state changes', async () => {
    const id = randomUUID()
    await data('create_task', { id, categoryId: 'inbox', title: 'Never fits', durationMinutes: 99999 })
    await data('update_task', { id, durationMinutes: 99998 })
    const journal = (await db.select().from(schema.scheduleChanges)).filter((row) => row.taskId === id)
    expect(journal).toHaveLength(2)
    expect(journal[1]?.changeType).toBe('unscheduled')
    expect(journal[0]?.afterUnscheduled?.unplacedMinutes).not.toBe(journal[1]?.afterUnscheduled?.unplacedMinutes)
    const projectId = randomUUID()
    await data('batch', { operations: [{ tool: 'create_project', arguments: { id: projectId, name: 'History' } }, { tool: 'delete_task', arguments: { id } }, { tool: 'delete_project', arguments: { id: projectId } }] })
    const at = new Date('2026-11-08T00:00:00Z')
    await db.update(schema.tasks).set({ updatedAt: at }).where(eq(schema.tasks.id, id))
    await db.update(schema.projects).set({ updatedAt: at }).where(eq(schema.projects.id, projectId))
    const out = await data('list_changes', { since: '2026-11-07T00:00:00Z' })
    expect(out.tasks.find((t: { id: string }) => t.id === id)).toMatchObject({ changeType: 'deleted', appUrl: `florida://tasks/${id}` })
    expect(out.projects.find((p: { id: string }) => p.id === projectId)).toMatchObject({ changeType: 'deleted', appUrl: `florida://projects/${projectId}` })
  })
})

describe('MCP free slots', () => {
  it('accepts zoned dates, caps at deadlines, filters context and limits results', async () => {
    const args = { windowStart: '2026-11-09', windowEnd: '2026-11-11', durationMinutes: 30, includeScheduledTasks: false }
    const out = await data('find_free_slots', { ...args, deadline: '2026-11-09', limit: 1 })
    expect(out.slots).toEqual([{ startAt: now.toISOString(), endAt: '2026-11-10T01:00:00.000Z', durationMinutes: 480 }])
    expect((await data('find_free_slots', { ...args, context: 'office' })).slots).toEqual([])
    expect((await data('find_free_slots', { ...args, deadline: '2026-11-09T18:00:00Z' })).slots).toEqual([{ startAt: now.toISOString(), endAt: '2026-11-09T18:00:00.000Z', durationMinutes: 60 }])
  })
  it('uses calendar blocking policy and optionally subtracts the current plan', async () => {
    const args = { windowStart: now.toISOString(), windowEnd: '2026-11-10T01:00:00Z', durationMinutes: 30 }
    const unplanned = await data('find_free_slots', { ...args, includeScheduledTasks: false })
    expect(unplanned.slots).toEqual([{ startAt: now.toISOString(), endAt: args.windowEnd.replace('Z', '.000Z'), durationMinutes: 480 }])
    const planned = await data('find_free_slots', args)
    expect(planned.slots).not.toEqual(unplanned.slots)
    await db.insert(schema.googleAccounts).values({ id: 'power-account', email: 'power@example.com', label: 'Power', refreshTokenEnc: 'test', accessToken: 'test' })
    await db.insert(schema.calendars).values({ id: 'power-calendar', accountId: 'power-account', googleId: 'power', summary: 'Power', accessRole: 'owner', selected: false, blocksScheduling: true })
    await db.insert(schema.events).values({ id: 'power-event', calendarId: 'power-calendar', googleId: 'power', status: 'confirmed', summary: 'Day off', allDay: true, blocksDay: true, startAt: new Date('2026-11-09T00:00:00Z'), endAt: new Date('2026-11-10T00:00:00Z') })
    expect((await data('find_free_slots', { ...args, includeScheduledTasks: false })).slots).toEqual([])
    await db.update(schema.events).set({ responseStatus: 'declined' }).where(eq(schema.events.id, 'power-event'))
    expect((await data('find_free_slots', { ...args, includeScheduledTasks: false })).slots).toEqual(unplanned.slots)
    await db.update(schema.events).set({ responseStatus: null }).where(eq(schema.events.id, 'power-event'))
    await db.update(schema.calendars).set({ blocksScheduling: false }).where(eq(schema.calendars.id, 'power-calendar'))
    expect((await data('find_free_slots', { ...args, includeScheduledTasks: false })).slots).toEqual(unplanned.slots)
    expect((await call('find_free_slots', { ...args, windowEnd: args.windowStart })).isError).toBe(true)
    expect((await call('find_free_slots', { ...args, windowEnd: '2027-01-01T00:00:00Z' })).isError).toBe(true)
  })

  it('returns event-triggered reschedule reasons and task details from list_changes', async () => {
    await db.update(schema.calendars).set({ selected: true, blocksScheduling: true }).where(eq(schema.calendars.id, 'power-calendar'))
    const { task } = await data('create_task', { categoryId: 'inbox', title: 'Moved by event', startAt: '2026-11-10T17:00:00Z' })
    const [block] = task.placements
    expect(block).toBeDefined()
    const http = createApp({ db, config: testConfig, sync: new FakeSync(), reschedule: (reason) => runScheduling(db, config, now, reason) })
    const response = await http.request(`/api/events/${randomUUID()}`, { method: 'PUT', headers: { authorization: 'Bearer ' + testConfig.API_TOKEN, 'content-type': 'application/json' }, body: JSON.stringify({ calendarId: 'power-calendar', summary: 'New meeting', startAt: block.startAt, endAt: block.endAt, allDay: false }) })
    expect(response.status).toBe(200)
    const [journal] = (await db.select().from(schema.scheduleChanges)).filter((row) => row.taskId === task.id && row.reason === 'rescheduled due to new event')
    expect(journal?.changeType).toBe('moved')
    await db.update(schema.scheduleChanges).set({ updatedAt: new Date('2026-11-08T00:00:00Z') }).where(eq(schema.scheduleChanges.id, journal!.id))
    const out = await data('list_changes', { since: '2026-11-07T00:00:00Z' })
    expect(out.placements.find((item: { id: string }) => item.id === journal!.id)).toMatchObject({ taskId: task.id, title: task.title, appUrl: `florida://tasks/${task.id}`, changeType: 'moved', reason: 'rescheduled due to new event' })
  })
})
