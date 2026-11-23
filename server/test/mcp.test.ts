import { randomUUID } from 'node:crypto'
import { dateFromDayNumber, dayNumber, localDate, weekdayOf, zonedToUtc } from '@florida/scheduler'
import type { LocalDate } from '@florida/scheduler'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { eq } from 'drizzle-orm'
import { Hono } from 'hono'
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import { createApp } from '../src/app.js'
import { ChangeBus } from '../src/changes.js'
import type { Db } from '../src/db/client.js'
import { briefs, calendars, dayOverrides, events, googleAccounts, placements, projectPlacements, projects, routineBlocks, routineOccurrences, scheduleChanges, tasks } from '../src/db/schema.js'
import type { TaskDraft, ParseTaskContext } from '../src/ai/parse-task.js'
import { GoogleApiError } from '../src/google/client.js'
import { mountMcp } from '../src/mcp.js'
import { runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import type { TaskSource } from '../src/task-source.js'
import { createTestDb } from './db.js'
import { FakeSync, testConfig as config } from './fixtures.js'

const LA = 'America/Los_Angeles'

vi.setSystemTime(new Date('2026-11-09T09:00:00-08:00'))

interface RpcResponse {
  jsonrpc: '2.0'
  id: number | null
  result?: Record<string, unknown>
  error?: { code: number; message: string }
}

interface ToolResult {
  content: { type: string; text?: string }[]
  structuredContent?: Record<string, unknown>
  isError?: boolean
}

interface TaskView {
  id: string
  title: string
  notes: string | null
  priority: string
  deadlineType: string
  dueAt: string | null
  completedAt: string | null
  completedMinutes: number
  tags: string[]
  waitingOn: string | null
  waitingUntil: string | null
  placements: { startAt: string; endAt: string; pinned: boolean }[]
}


let db: Db
let close: () => Promise<void>
let app: Hono
let notices = 0
let nextRpcId = 1

const headers = {
  authorization: `Bearer ${config.API_TOKEN}`,
  'content-type': 'application/json',
  accept: 'application/json, text/event-stream',
}

beforeAll(async () => {
  ;({ db, close } = await createTestDb())
  await seed(db)
  const changes = new ChangeBus()
  changes.subscribe(() => {
    notices += 1
  })
  app = createApp({ db, config, sync: new FakeSync(), reschedule: (reason) => runScheduling(db, config, new Date(), reason), changes })
})

afterAll(async () => {
  try {
    await close()
  } finally {
    vi.useRealTimers()
  }
})

async function post(body: unknown, extraHeaders: Record<string, string> = {}): Promise<Response> {
  return app.request('/mcp', { method: 'POST', headers: { ...headers, ...extraHeaders }, body: JSON.stringify(body) })
}

async function rpc(method: string, params?: unknown): Promise<RpcResponse> {
  const id = nextRpcId++
  const res = await post({ jsonrpc: '2.0', id, method, ...(params === undefined ? {} : { params }) })
  expect(res.status).toBe(200)
  expect(res.headers.get('content-type')).toContain('application/json')
  const body = (await res.json()) as RpcResponse
  expect(body.id).toBe(id)
  return body
}

async function call(name: string, args: Record<string, unknown> = {}): Promise<ToolResult> {
  const body = await rpc('tools/call', { name, arguments: args })
  expect(body.error).toBeUndefined()
  return body.result as unknown as ToolResult
}

/** Calls a tool that must succeed and returns its structured content. */
async function data<T = Record<string, unknown>>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  const result = await call(name, args)
  expect(result.isError, result.content[0]?.text).toBeFalsy()
  expect(result.structuredContent).toBeDefined()
  // The text block carries the same payload for clients that ignore structured content.
  expect(JSON.parse(result.content[0]?.text ?? 'null')).toEqual(result.structuredContent)
  return result.structuredContent as T
}

/** The first Monday at least two days out, so every fixture lands inside the scheduler horizon on a workday. */
function upcomingMonday(): LocalDate {
  let day = dayNumber(localDate(Date.now(), LA)) + 2
  while (weekdayOf(dateFromDayNumber(day)) !== 1) day += 1
  return dateFromDayNumber(day)
}

function at(date: LocalDate, minutesOfDay: number): Date {
  return new Date(zonedToUtc(date, minutesOfDay, LA))
}

function utcMidnight(date: LocalDate): Date {
  return new Date(Date.UTC(date.year, date.month - 1, date.day))
}

function ymd(date: LocalDate): string {
  return `${date.year}-${String(date.month).padStart(2, '0')}-${String(date.day).padStart(2, '0')}`
}

describe('transport and auth', () => {
  it('requires the API token', async () => {
    const init = { jsonrpc: '2.0', id: 1, method: 'tools/list' }
    expect((await post(init, { authorization: 'Bearer nope' })).status).toBe(401)
    const res = await app.request('/mcp', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' })
    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: 'unauthorized' })
  })

  it('answers GET and DELETE with a 405 JSON-RPC error (no sessions)', async () => {
    for (const method of ['GET', 'DELETE']) {
      const res = await app.request('/mcp', { method, headers })
      expect(res.status).toBe(405)
      expect(await res.json()).toMatchObject({ jsonrpc: '2.0', error: { code: -32000 }, id: null })
    }
  })

  it('initializes statelessly in JSON mode', async () => {
    const res = await post({
      jsonrpc: '2.0',
      id: 99,
      method: 'initialize',
      params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'vitest', version: '0.0.0' } },
    })
    expect(res.status).toBe(200)
    expect(res.headers.get('content-type')).toContain('application/json')
    expect(res.headers.get('mcp-session-id')).toBeNull()
    expect(await res.json()).toMatchObject({
      jsonrpc: '2.0',
      id: 99,
      result: {
        protocolVersion: '2025-11-25',
        capabilities: { tools: {} },
        serverInfo: { name: 'florida' },
        instructions: expect.stringContaining('Florida'),
      },
    })
  })

  it('lists the tools with input schemas', async () => {
    const body = await rpc('tools/list')
    const tools = (body.result as { tools: { name: string; inputSchema: { type: string; properties?: object } }[] }).tools
    expect(tools.map((t) => t.name).sort()).toEqual([
      'archive_later',
      'batch',
      'batch_create_tasks',
      'batch_update_tasks',
      'clear_day',
      'complete_task',
      'create_project',
      'create_task',
      'delete_project',
      'delete_event',
      'delete_task',
      'find_free_slots',
      'get_agenda',
      'get_brief',
      'get_range',
      'get_task',
      'list_categories',
      'list_calendars',
      'list_changes',
      'list_deleted_tasks',
      'list_later',
      'list_projects',
      'list_tasks',
      'mark_later_read',
      'parse_task',
      'restore_task',
      'run_scheduler',
      'save_later',
      'set_day',
      'set_event_blocks_day',
      'sync_google_calendar',
      'update_project',
      'update_task',
      'upsert_event',
    ].sort())
    const create = tools.find((t) => t.name === 'create_task')
    expect(create?.inputSchema.type).toBe('object')
    expect(Object.keys(create?.inputSchema.properties ?? {})).toEqual(
      expect.arrayContaining(['categoryId', 'title', 'durationMinutes', 'priority', 'dueAt', 'id']),
    )
  })

  it('reports invalid tool arguments as a tool error that names the field', async () => {
    // The SDK validates arguments against the zod shape and returns the failure as an isError
    // result (not a JSON-RPC error), so the model can read it and retry.
    const result = await call('create_task', { categoryId: 'inbox', title: 'x', durationMinutes: 0 })
    expect(result.isError).toBe(true)
    expect(result.content[0]?.text).toContain('durationMinutes')
    expect(result.structuredContent).toBeUndefined()
  })
})

describe('Later tools', () => {
  it('saves, lists, reads and archives a video without creating a task', async () => {
    const id = randomUUID()
    const url = 'https://youtu.be/example#t=30'
    const noticesBefore = notices
    const saved = await data('save_later', { id, url, estMinutes: 8 })
    expect(saved.item).toMatchObject({ id, url, source: 'mcp', kind: 'video', estMinutes: 8, readAt: null, archivedAt: null })
    expect(await data('save_later', { id, url })).toEqual(saved)
    expect((await data('list_later')).items).toEqual([saved.item])
    const read = await data('mark_later_read', { id })
    expect(read.item).toMatchObject({ id, readAt: expect.any(String), archivedAt: null })
    expect((await data('list_later')).items).toEqual([])
    expect((await data('list_later', { status: 'read' })).items).toEqual([read.item])
    const archived = await data('archive_later', { id })
    expect(archived.item).toMatchObject({ id, archivedAt: expect.any(String), deletedAt: null })
    expect((await data('list_later', { status: 'archived' })).items).toEqual([archived.item])
    expect(await db.select().from(tasks).where(eq(tasks.id, id))).toEqual([])
    expect(notices - noticesBefore).toBeGreaterThanOrEqual(3)
  })

  it('rejects non-web URLs and missing item ids', async () => {
    expect((await call('save_later', { url: 'mailto:later@example.com' })).isError).toBe(true)
    expect((await call('archive_later', { id: 'missing-later' })).isError).toBe(true)
  })
})

describe('task tools', () => {
  it('accepts sources, exposes them in reads, preserves omitted values, and updates and clears them', async () => {
    const id = 'mcp-source'
    const url = 'https://github.com/acme/app/issues/42'
    const source = { url, title: 'Issue #42 in acme/app', kind: 'github' }
    const created = await data<{ task: TaskView & { source: TaskSource | null } }>('create_task', { id, categoryId: 'inbox', title: 'Fix', source: { url, kind: 'web' } })
    expect(created.task.source).toEqual(source)
    expect((await data<{ task: { source: TaskSource } }>('get_task', { id })).task.source).toEqual(source)
    expect((await data<{ tasks: { id: string; source: TaskSource | null }[] }>('list_tasks', { limit: 200 })).tasks.find((task) => task.id === id)?.source).toEqual(source)
    expect((await data<{ task: { source: TaskSource } }>('update_task', { id, notes: 'keep link' })).task.source).toEqual(source)
    const replacement = { url: 'mailto:person@example.com', title: 'Email thread', kind: 'email' }
    expect((await data<{ task: { source: TaskSource } }>('update_task', { id, source: { ...replacement, kind: 'slack' } })).task.source).toEqual(replacement)
    expect((await data<{ task: { source: null } }>('update_task', { id, source: null })).task.source).toBeNull()
    expect((await data<{ task: { source: null } }>('get_task', { id })).task.source).toBeNull()
    for (const url of ['javascript:alert(1)', 'file:///etc/passwd', 'data:text/html,bad']) {
      for (const tool of ['create_task', 'update_task']) {
        const rejected = await call(tool, { id: tool === 'create_task' ? 'mcp-source-rejected' : id, categoryId: 'inbox', title: 'Unsafe', source: { url } })
        expect(rejected.isError).toBe(true)
        expect(rejected.content[0]?.text).toContain('source')
      }
    }
    expect((await call('get_task', { id: 'mcp-source-rejected' })).isError).toBe(true)
    await data('delete_task', { id })
  })

  let createdId = ''
  const dueAt = at(upcomingMonday(), 17 * 60).toISOString()

  it('list_categories returns the seeded category', async () => {
    const { categories } = await data<{ categories: { id: string; scheduleId: string }[] }>('list_categories')
    expect(categories).toEqual([
      expect.objectContaining({ id: 'inbox', scheduleId: 'work' }),
      expect.objectContaining({ id: 'work', scheduleId: 'work' }),
      expect.objectContaining({ id: 'personal', scheduleId: 'personal' }),
    ])
  })

  it('create_task generates an id, derives the deadline type, schedules, and notifies clients', async () => {
    const before = notices
    const out = await data<{ task: TaskView; scheduling: { unscheduled: unknown[]; late: unknown[] } }>('create_task', {
      categoryId: 'inbox',
      title: 'Write the report',
      notes: 'bring the numbers',
      dueAt,
    })
    createdId = out.task.id
    expect(createdId).toMatch(/^[0-9a-f-]{36}$/)
    expect(out.task).toMatchObject({ title: 'Write the report', priority: 'medium', deadlineType: 'soft', dueAt })
    expect(out.task.placements).toHaveLength(1)
    expect(new Date(out.task.placements[0]!.endAt).getTime() - new Date(out.task.placements[0]!.startAt).getTime()).toBe(
      30 * 60_000,
    )
    expect(out.scheduling).toEqual({ unscheduled: [], late: [] })
    expect(Object.keys(out.scheduling)).not.toContain('placements')
    expect(notices).toBe(before + 1)

    const rows = await db.select().from(tasks).where(eq(tasks.id, createdId))
    expect(rows).toHaveLength(1)
  })

  it('create_task without dueAt defaults to no deadline and honours a client id', async () => {
    const out = await data<{ task: TaskView }>('create_task', { id: 'mcp-fixed', categoryId: 'inbox', title: 'Undated' })
    expect(out.task).toMatchObject({ id: 'mcp-fixed', deadlineType: 'none', dueAt: null, completedMinutes: 0 })
  })

  it('create_task rejects an unknown category as a tool error', async () => {
    const result = await call('create_task', { categoryId: 'nope', title: 'x' })
    expect(result.isError).toBe(true)
    expect(result.content[0]?.text).toBe('unknown categoryId nope')
    expect(result.structuredContent).toBeUndefined()
  })

  it('list_tasks orders dated tasks first, filters by category, and attaches placements', async () => {
    const { tasks: all } = await data<{ tasks: TaskView[] }>('list_tasks')
    expect(all.map((t) => t.id)).toEqual([createdId, 'mcp-fixed'])
    expect(all[0]?.placements).toHaveLength(1)
    const { tasks: none } = await data<{ tasks: TaskView[] }>('list_tasks', { categoryId: 'other' })
    expect(none).toEqual([])
  })

  it('update_task keeps omitted fields, clears with null, and reschedules', async () => {
    const renamed = await data<{ task: TaskView }>('update_task', { id: createdId, title: 'Write the Q4 report', priority: 'asap' })
    expect(renamed.task).toMatchObject({ title: 'Write the Q4 report', priority: 'asap', notes: 'bring the numbers', dueAt })

    const cleared = await data<{ task: TaskView }>('update_task', { id: createdId, notes: null, dueAt: null })
    expect(cleared.task).toMatchObject({ title: 'Write the Q4 report', notes: null, dueAt: null })

    const missing = await call('update_task', { id: 'ghost', title: 'x' })
    expect(missing.isError).toBe(true)
    expect(missing.content[0]?.text).toBe('task ghost not found')
  })

  it('get_task returns one task with placements', async () => {
    const { task } = await data<{ task: TaskView }>('get_task', { id: createdId })
    expect(task.id).toBe(createdId)
    expect(task.placements).toHaveLength(1)
  })

  it('complete_task credits the duration, drops placements, and hides the task from list_tasks', async () => {
    const { task } = await data<{ task: TaskView }>('complete_task', { id: 'mcp-fixed' })
    expect(task.completedAt).not.toBeNull()
    expect(task.completedMinutes).toBe(30)

    const open = await data<{ tasks: TaskView[] }>('list_tasks')
    expect(open.tasks.map((t) => t.id)).toEqual([createdId])
    const withDone = await data<{ tasks: TaskView[] }>('list_tasks', { includeCompleted: true })
    expect(withDone.tasks.map((t) => t.id).sort()).toEqual([createdId, 'mcp-fixed'].sort())
    expect(withDone.tasks.find((t) => t.id === 'mcp-fixed')?.placements).toEqual([])

    const again = await data<{ task: TaskView }>('complete_task', { id: 'mcp-fixed' })
    expect(again.task.completedAt).toBe(task.completedAt)
  })

  it('delete_task tombstones the task; later reads fail as tool errors', async () => {
    const out = await data<{ deleted: string }>('delete_task', { id: 'mcp-fixed' })
    expect(out.deleted).toBe('mcp-fixed')
    const gone = await call('get_task', { id: 'mcp-fixed' })
    expect(gone.isError).toBe(true)
    const never = await call('delete_task', { id: 'never-existed' })
    expect(never.isError).toBe(true)
    expect(never.content[0]?.text).toBe('task never-existed not found')
  })

  it('run_scheduler returns the full result', async () => {
    const { scheduling } = await data<{ scheduling: { placements: { taskId: string }[]; unscheduled: unknown[]; late: unknown[] } }>(
      'run_scheduler',
    )
    expect(scheduling.placements.map((p) => p.taskId)).toEqual([createdId])
    expect(scheduling.unscheduled).toEqual([])
  })

  it('creates custom recurring tasks, completes one occurrence, and stops repeats through update_task', async () => {
    const recurrence = { frequency: 'week', interval: 2, timeZone: LA, startDate: ymd(upcomingMonday()), weekdays: [1, 4] }
    const { task } = await data<{ task: TaskView & { recurrenceSeriesId: string; recurrence: object } }>('create_task', {
      categoryId: 'work', title: 'Recurring review', recurrence,
    })
    expect(task.recurrence).toEqual(recurrence)
    const { task: done } = await data<{ task: TaskView }>('complete_task', { id: task.id })
    expect(done.completedAt).not.toBeNull()
    const { tasks: open } = await data<{ tasks: (TaskView & { recurrenceSeriesId: string | null })[] }>('list_tasks')
    const next = open.find((candidate) => candidate.recurrenceSeriesId === task.recurrenceSeriesId)
    expect(next).toBeDefined()
    const { task: standalone } = await data<{ task: TaskView & { recurrence: null } }>('update_task', { id: next!.id, recurrence: null })
    expect(standalone.recurrence).toBeNull()
    const { tasks: remaining } = await data<{ tasks: (TaskView & { recurrenceSeriesId: string | null })[] }>('list_tasks')
    expect(remaining.filter((candidate) => candidate.recurrenceSeriesId === task.recurrenceSeriesId)).toEqual([])
    await data('delete_task', { id: standalone.id })
    await data('delete_task', { id: task.id })
  })
})

describe('get_agenda', () => {
  const monday = upcomingMonday()
  const sunday = dateFromDayNumber(dayNumber(monday) - 1)
  const tuesday = dateFromDayNumber(dayNumber(monday) + 1)
  const wednesday = dateFromDayNumber(dayNumber(monday) + 2)

  beforeAll(async () => {
    await db.insert(googleAccounts).values({ id: 'acc-1', email: 'me@example.com', label: 'work', refreshTokenEnc: 'x' })
    await db.insert(calendars).values([
      { id: 'cal-1', accountId: 'acc-1', googleId: 'me@example.com', summary: 'Work', accessRole: 'owner' },
      { id: 'cal-off', accountId: 'acc-1', googleId: 'holidays', summary: 'Holidays', accessRole: 'reader', selected: false },
    ])
    const base = { calendarId: 'cal-1', status: 'confirmed' }
    await db.insert(events).values([
      // Timed, inside the day.
      {
        ...base,
        id: 'ev-standup',
        googleId: 'g1',
        summary: 'Standup',
        startAt: at(monday, 10 * 60),
        endAt: at(monday, 10 * 60 + 30),
        allDay: false,
        description: 'Blockers first',
        conferenceUrl: 'https://meet.google.com/abc-defg-hij',
        attendees: [
          { email: 'me@example.com', displayName: 'Me', responseStatus: 'accepted', organizer: true, self: true, optional: false },
          { email: 'pm@example.com', displayName: null, responseStatus: 'tentative', organizer: false, self: false, optional: true },
        ],
      },
      // Sunday 23:00 Pacific is Monday 07:00Z: a UTC-day query would wrongly include it.
      { ...base, id: 'ev-late', googleId: 'g2', summary: 'Late call', startAt: at(sunday, 23 * 60), endAt: at(sunday, 23 * 60 + 30), allDay: false },
      // All-day rows sit at UTC midnight of their calendar date.
      { ...base, id: 'ev-holiday', googleId: 'g3', summary: 'Holiday', startAt: utcMidnight(monday), endAt: utcMidnight(tuesday), allDay: true },
      // Tuesday's all-day event starts Monday 16:00 Pacific: a zoned query would wrongly include it.
      { ...base, id: 'ev-trip', googleId: 'g4', summary: 'Trip', startAt: utcMidnight(tuesday), endAt: utcMidnight(wednesday), allDay: true },
      // Unselected calendar: never shown.
      { ...base, calendarId: 'cal-off', id: 'ev-off', googleId: 'g5', summary: 'Hidden', startAt: at(monday, 12 * 60), endAt: at(monday, 13 * 60), allDay: false },
    ])
    await data('create_task', { id: 'pinned', categoryId: 'inbox', title: 'Pinned block', durationMinutes: 60, pinnedStart: at(monday, 13 * 60).toISOString() })
  })

  it('returns the zoned day: all-day events first, then timed events and task blocks', async () => {
    const out = await data<{
      date: string
      timeZone: string
      start: string
      end: string
      events: { id: string; summary: string; calendar: string; allDay: boolean }[]
      taskBlocks: { taskId: string; title: string; startAt: string; endAt: string; pinned: boolean }[]
    }>('get_agenda', { date: ymd(monday), timeZone: LA })
    expect(out).toMatchObject({ date: ymd(monday), timeZone: LA })
    expect(out.start).toBe(at(monday, 0).toISOString())
    expect(out.end).toBe(at(tuesday, 0).toISOString())
    expect(out.events.map((e) => e.id)).toEqual(['ev-holiday', 'ev-standup'])
    expect(out.events[0]).toMatchObject({ calendar: 'Work', allDay: true })
    expect(out.events[1]).toMatchObject({
      description: 'Blockers first',
      conferenceUrl: 'https://meet.google.com/abc-defg-hij',
      attendees: [
        { email: 'me@example.com', displayName: 'Me', responseStatus: 'accepted', organizer: true, self: true, optional: false },
        { email: 'pm@example.com', displayName: null, responseStatus: 'tentative', organizer: false, self: false, optional: true },
      ],
    })
    expect(out.events[0]).toMatchObject({ description: null, conferenceUrl: null, attendees: null })
    expect(out.taskBlocks).toEqual([
      expect.objectContaining({
        taskId: 'pinned',
        title: 'Pinned block',
        startAt: at(monday, 13 * 60).toISOString(),
        endAt: at(monday, 14 * 60).toISOString(),
        pinned: true,
      }),
    ])
  })

  it('places the late Sunday call and the Tuesday trip on their own days', async () => {
    const sun = await data<{ events: { id: string }[] }>('get_agenda', { date: ymd(sunday), timeZone: LA })
    expect(sun.events.map((e) => e.id)).toEqual(['ev-late'])
    const tue = await data<{ events: { id: string }[]; taskBlocks: unknown[] }>('get_agenda', { date: ymd(tuesday), timeZone: LA })
    expect(tue.events.map((e) => e.id)).toEqual(['ev-trip'])
  })

  it('defaults to today in the first schedule’s time zone', async () => {
    const out = await data<{ date: string; timeZone: string }>('get_agenda')
    expect(out.timeZone).toBe(LA)
    expect(out.date).toBe(ymd(localDate(Date.now(), LA)))
  })

  it('rejects impossible dates and unknown zones at the schema', async () => {
    const bad = await call('get_agenda', { date: '2026-02-30' })
    expect(bad.isError).toBe(true)
    expect(bad.content[0]?.text).toContain('YYYY-MM-DD')
    const zone = await call('get_agenda', { timeZone: 'Mars/Olympus' })
    expect(zone.isError).toBe(true)
    expect(zone.content[0]?.text).toContain('time zone')
  })
})

describe('project and day tools', () => {
  // The day after the agenda fixtures: an office day whose only event is all-day.
  const tuesday = dateFromDayNumber(dayNumber(upcomingMonday()) + 1)
  const wednesday = dateFromDayNumber(dayNumber(tuesday) + 1)
  const gymEnd = at(tuesday, 10 * 60 + 15).toISOString()

  interface ProjectView {
    id: string
    name: string
    status: string
    parallel: boolean
    openTasks?: number
  }
  interface Agenda {
    taskBlocks: { taskId: string; startAt: string; endAt: string; lane: number | null; projectId: string | null }[]
    projectTime: { projectId: string; project: string; startAt: string; endAt: string; lane: number | null }[]
    commitments: { name: string; startAt: string; endAt: string }[]
    dayOverride: { kind: string; note: string | null } | null
  }
  const agenda = (date: LocalDate) => data<Agenda>('get_agenda', { date: ymd(date), timeZone: LA })
  const mine = (out: Agenda) => out.taskBlocks.filter((b) => b.taskId === 'mcp-a' || b.taskId === 'mcp-b')
  let billingId = ''

  it('create_project generates an id, reschedules and notifies clients; an unknown category is a tool error', async () => {
    const before = notices
    const atlas = await data<{ project: ProjectView; scheduling: object }>('create_project', {
      id: 'mcp-atlas',
      name: 'Atlas',
      parallel: true,
      nextStep: 'Wire the lanes',
    })
    expect(atlas.project).toMatchObject({ id: 'mcp-atlas', name: 'Atlas', status: 'active', parallel: true, nextStep: 'Wire the lanes', weeklyMinutes: null })
    expect(Object.keys(atlas.scheduling)).toEqual(['unscheduled', 'late'])
    expect(notices).toBe(before + 1)

    const billing = await data<{ project: ProjectView }>('create_project', { name: 'Billing', parallel: true })
    billingId = billing.project.id
    expect(billingId).toMatch(/^[0-9a-f-]{36}$/)

    const bad = await call('create_project', { name: 'X', categoryId: 'nope' })
    expect(bad.isError).toBe(true)
    expect(bad.content[0]?.text).toBe('unknown categoryId nope')
    expect((await call('create_project', { name: 'X', status: 'paused' })).isError).toBe(true)
  })

  it('get_agenda shows two parallel projects side by side in lanes, after the gym', async () => {
    const task = { categoryId: 'inbox', durationMinutes: 60, priority: 'asap', startAt: at(tuesday, 0).toISOString() }
    await data('create_task', { ...task, id: 'mcp-a', title: 'Atlas migration', projectId: 'mcp-atlas' })
    await data('create_task', { ...task, id: 'mcp-b', title: 'Billing export', projectId: billingId })
    const unknown = await call('create_task', { ...task, title: 'x', projectId: 'nope' })
    expect(unknown.content[0]?.text).toBe('unknown projectId nope')

    const out = await agenda(tuesday)
    expect(out.dayOverride).toBeNull()
    expect(out.commitments).toEqual([{ name: 'Gym', startAt: at(tuesday, 9 * 60).toISOString(), endAt: gymEnd }])
    const blocks = mine(out)
    expect(blocks.map((b) => [b.taskId, b.lane, b.projectId])).toEqual([
      ['mcp-a', 0, 'mcp-atlas'],
      ['mcp-b', 1, billingId],
    ])
    expect(blocks[1]?.startAt).toBe(blocks[0]?.startAt)
    expect(blocks[0]!.startAt >= gymEnd).toBe(true)
  })

  it('list_projects counts open tasks and filters by status; update_project takes a project out of the plan and back', async () => {
    const all = await data<{ projects: ProjectView[] }>('list_projects')
    expect(all.projects.map((p) => [p.name, p.openTasks])).toEqual([
      ['Atlas', 1],
      ['Billing', 1],
    ])

    const held = await data<{ project: ProjectView }>('update_project', { id: 'mcp-atlas', status: 'on_hold' })
    // The fields the update does not name are kept.
    expect(held.project).toMatchObject({ status: 'on_hold', parallel: true, nextStep: 'Wire the lanes' })
    expect((await data<{ projects: ProjectView[] }>('list_projects', { status: 'active' })).projects.map((p) => p.name)).toEqual(['Billing'])
    expect((await data<{ projects: ProjectView[] }>('list_projects', { status: 'on_hold' })).projects.map((p) => p.name)).toEqual(['Atlas'])
    expect((await data<{ task: TaskView }>('get_task', { id: 'mcp-a' })).task.placements).toEqual([])
    expect((await data<{ task: TaskView }>('get_task', { id: 'mcp-b' })).task.placements).toHaveLength(1)

    await data('update_project', { id: 'mcp-atlas', status: 'active', nextStep: null })
    expect((await data<{ task: TaskView }>('get_task', { id: 'mcp-a' })).task.placements).toHaveLength(1)
    const never = await call('update_project', { id: 'never-existed', status: 'done' })
    expect(never.isError).toBe(true)
    expect(never.content[0]?.text).toBe('project never-existed not found')
  })

  it('a weekly budget shows up in get_agenda as project time, clear of the gym', async () => {
    // Ten hours is more than Monday holds, so some of next week's has to land on Tuesday.
    await data('create_project', { id: 'mcp-budget', name: 'Budget', weeklyMinutes: 600 })
    const out = await agenda(tuesday)
    expect(out.projectTime.length).toBeGreaterThan(0)
    for (const block of out.projectTime) {
      expect(block).toMatchObject({ projectId: 'mcp-budget', project: 'Budget', lane: null })
      expect(block.startAt >= gymEnd).toBe(true)
      for (const task of out.taskBlocks) expect(block.startAt >= task.endAt || block.endAt <= task.startAt).toBe(true)
    }
    // Project time is not a task: nothing reports it as unscheduled or late, and no task list has it.
    const run = await data<{ scheduling: { placements: { taskId: string }[]; unscheduled: { taskId: string }[]; late: { taskId: string }[] } }>('run_scheduler')
    for (const list of [run.scheduling.placements, run.scheduling.unscheduled, run.scheduling.late]) {
      expect(list.filter((entry) => entry.taskId.startsWith('project-time:'))).toEqual([])
    }
  })

  it('set_day off clears the date, with its gym, and clear_day puts it back', async () => {
    const before = notices
    const set = await data<{ dayOverride: { date: string; kind: string; note: string | null } }>('set_day', {
      date: ymd(tuesday),
      kind: 'off',
      note: 'Dentist',
    })
    expect(set.dayOverride).toMatchObject({ date: ymd(tuesday), kind: 'off', note: 'Dentist' })
    expect(notices).toBe(before + 1)
    const off = await agenda(tuesday)
    expect(off).toMatchObject({ dayOverride: { kind: 'off', note: 'Dentist' }, commitments: [], taskBlocks: [], projectTime: [] })
    // The tasks move to the next day, and so does the office-morning gym session.
    const next = await agenda(wednesday)
    expect(mine(next).map((b) => b.taskId)).toEqual(['mcp-a', 'mcp-b'])
    expect(next.commitments).toEqual([{ name: 'Gym', startAt: at(wednesday, 9 * 60).toISOString(), endAt: at(wednesday, 10 * 60 + 15).toISOString() }])

    expect(await data('clear_day', { date: ymd(tuesday) })).toMatchObject({ cleared: ymd(tuesday) })
    const back = await agenda(tuesday)
    expect(back.dayOverride).toBeNull()
    expect(back.commitments).toHaveLength(1)

    expect((await call('set_day', { date: '2026-02-30', kind: 'off' })).isError).toBe(true)
    expect((await call('set_day', { date: ymd(tuesday), kind: 'vacation' })).isError).toBe(true)
    const never = await call('clear_day', { date: '2031-01-01' })
    expect(never.isError).toBe(true)
    expect(never.content[0]?.text).toBe('day override 2031-01-01 not found')
  })

  it('delete_project tombstones the project and leaves its tasks, without a project', async () => {
    expect(await data('delete_project', { id: 'mcp-atlas' })).toMatchObject({ deleted: 'mcp-atlas' })
    await data('delete_project', { id: 'mcp-budget' })
    expect((await data<{ projects: ProjectView[] }>('list_projects')).projects.map((p) => p.name)).toEqual(['Billing'])
    const [row] = await db.select().from(tasks).where(eq(tasks.id, 'mcp-a'))
    expect(row).toMatchObject({ projectId: null, deletedAt: null })
    expect((await agenda(tuesday)).projectTime).toEqual([])
    const never = await call('delete_project', { id: 'never-existed' })
    expect(never.isError).toBe(true)
    expect(never.content[0]?.text).toBe('project never-existed not found')
  })

  it('get_brief returns the newest brief of each kind', async () => {
    expect(await data('get_brief')).toEqual({ briefs: [] })
    await db.insert(briefs).values([
      { id: 'b-old', kind: 'daily', date: '2026-11-09', headline: 'Yesterday', body: 'Old news' },
      { id: 'b-new', kind: 'daily', date: '2026-11-10', headline: 'Two projects side by side', body: 'Atlas and Billing from 10:15.' },
      { id: 'b-week', kind: 'weekly', date: '2026-11-08', headline: 'A full week', body: 'Four gym sessions.' },
    ])
    const out = await data<{ briefs: { id: string; kind: string; headline: string }[] }>('get_brief')
    expect(out.briefs.map((b) => [b.id, b.kind, b.headline])).toEqual([
      ['b-new', 'daily', 'Two projects side by side'],
      ['b-week', 'weekly', 'A full week'],
    ])
  })
})

describe('official client', () => {
  it('connects, lists tools and calls one through app.request', async () => {
    const transport = new StreamableHTTPClientTransport(new URL('http://florida.test/mcp'), {
      fetch: async (url, init) => app.request(url, init),
      requestInit: { headers: { authorization: `Bearer ${config.API_TOKEN}` } },
    })
    const client = new Client({ name: 'vitest', version: '0.0.0' })
    await client.connect(transport)
    try {
      expect(client.getServerVersion()).toMatchObject({ name: 'florida' })
      const { tools } = await client.listTools()
      expect(tools.map((t) => t.name)).toContain('get_agenda')
      const result = await client.callTool({ name: 'list_categories' })
      expect(result.isError).toBeFalsy()
      expect((result.structuredContent as { categories: { id: string }[] }).categories.map((p) => p.id)).toEqual(['inbox', 'work', 'personal'])
    } finally {
      await client.close()
    }
  })
})

describe('Wave 1A filters and deep links', () => {
  const ids = Array.from({ length: 5 }, () => randomUUID())
  const projectId = randomUUID()
  const day = '2026-11-01'
  const matchingIds = async (filters: Record<string, unknown>) => (await data<{ tasks: TaskView[] }>('list_tasks', filters)).tasks.map((task) => task.id).filter((id) => ids.includes(id))

  beforeAll(async () => {
    await db.insert(projects).values({ id: projectId, name: 'Filter project', status: 'active' })
    await db.insert(tasks).values([
      { id: ids[0]!, categoryId: 'inbox', title: 'Needle 100%_ done', notes: 'Alpha', context: 'office' as const, priority: 'asap' as const, projectId, dueAt: new Date('2026-11-01T07:00:00Z'), source: { url: 'https://example.com', title: 'Example', kind: 'web' as const } },
      { id: ids[1]!, categoryId: 'inbox', title: 'Other task', notes: 'nEeDlE', context: 'computer' as const, priority: 'low' as const, dueAt: new Date('2026-11-02T07:59:59.999Z') },
      { id: ids[2]!, categoryId: 'inbox', title: 'Undated', someday: true },
      { id: ids[3]!, categoryId: 'inbox', title: 'Outside', dueAt: new Date('2026-11-02T08:00:00Z'), pinnedStart: new Date('2026-11-02T08:00:00Z') },
      { id: ids[4]!, categoryId: 'inbox', title: 'Pinned', dueAt: new Date('2026-11-01T06:59:59.999Z'), pinnedStart: new Date('2026-11-02T07:59:59.999Z') },
    ].map((task) => ({ durationMinutes: 30, priority: 'medium' as const, deadlineType: 'soft' as const, ...task })))
    await db.insert(placements).values([
      { id: randomUUID(), computedAt: new Date(), taskId: ids[0]!, startAt: new Date('2026-11-01T06:30:00Z'), endAt: new Date('2026-11-01T07:30:00Z'), pinned: false },
      { id: randomUUID(), computedAt: new Date(), taskId: ids[1]!, startAt: new Date('2026-11-02T08:00:00Z'), endAt: new Date('2026-11-02T08:30:00Z'), pinned: false },
    ])
  })

  it('matches title or notes case-insensitively, trims query, and treats wildcards literally', async () => {
    expect((await matchingIds({ query: '  NEEDLE ' })).sort()).toEqual([ids[0], ids[1]].sort())
    expect(await matchingIds({ query: '100%_' })).toEqual([ids[0]])
    expect((await matchingIds({ query: '   ' })).sort()).toEqual([...ids].sort())
  })

  it('uses inclusive timestamp bounds and the entire 25-hour local DST day for dates', async () => {
    expect((await matchingIds({ dueAfter: day, dueBefore: day })).sort()).toEqual([ids[0], ids[1]].sort())
    expect(await matchingIds({ dueAfter: '2026-11-01T07:00:00Z', dueBefore: '2026-11-01T07:00:00Z' })).toEqual([ids[0]])
    expect((await matchingIds({ dueBefore: day })).sort()).toEqual([ids[0], ids[1], ids[4]].sort())
    expect((await call('list_tasks', { dueBefore: '2026-02-30' })).isError).toBe(true)
  })

  it('filters context, priority, project, someday, source, and combinations', async () => {
    expect(await matchingIds({ context: 'office', priority: 'asap', projectId, hasSource: true, someday: false })).toEqual([ids[0]])
    for (const projectId of [null, 'none']) expect((await matchingIds({ projectId })).sort()).toEqual(ids.slice(1).sort())
    expect(await matchingIds({ someday: true })).toEqual([ids[2]])
    expect((await matchingIds({ someday: false })).sort()).toEqual(ids.filter((id) => id !== ids[2]).sort())
    expect((await matchingIds({ hasSource: false })).sort()).toEqual(ids.slice(1).sort())
    expect((await matchingIds({ context: 'computer', priority: 'low' }))).toEqual([ids[1]])
    expect((await call('list_tasks', { projectId: 'bad' })).isError).toBe(true)
    expect((await call('list_tasks', { context: 'phone' })).isError).toBe(true)
  })

  it('matches overlapping placements or pins in the local half-open day', async () => {
    expect((await matchingIds({ scheduledOn: day })).sort()).toEqual([ids[0], ids[4]].sort())
    const agenda = await data<{ taskBlocks: { taskId: string, appUrl: string }[] }>('get_agenda', { date: day })
    expect(agenda.taskBlocks.find((block) => block.taskId === ids[0])?.appUrl).toBe(`florida://tasks/${ids[0]}`)
  })

  it('adds appUrl to task and project reads and writes', async () => {
    const created = await data<{ task: TaskView & { appUrl: string } }>('create_task', { categoryId: 'inbox', title: 'Link task' })
    const id = created.task.id
    expect(created.task.appUrl).toBe(`florida://tasks/${id}`)
    for (const [tool, args] of [['get_task', { id }], ['update_task', { id, notes: 'Updated' }], ['complete_task', { id }]] as const) {
      expect((await data<{ task: { appUrl: string } }>(tool, args)).task.appUrl).toBe(`florida://tasks/${id}`)
    }
    expect((await data<{ tasks: { id: string, appUrl: string }[] }>('list_tasks', { includeCompleted: true })).tasks.find((task) => task.id === id)?.appUrl).toBe(`florida://tasks/${id}`)
    const createdProject = await data<{ project: { id: string, appUrl: string } }>('create_project', { name: 'Link project' })
    const project = createdProject.project
    expect(project.appUrl).toBe(`florida://projects/${project.id}`)
    expect((await data<{ project: { appUrl: string } }>('update_project', { id: project.id, name: 'Renamed' })).project.appUrl).toBe(project.appUrl)
    expect((await data<{ projects: { id: string, appUrl: string }[] }>('list_projects')).projects.find((p) => p.id === project.id)?.appUrl).toBe(project.appUrl)
  })
})

describe('Wave 1A range and restore tools', () => {
  it('returns the same agenda shape for every day, including DST and an all-day span', async () => {
    const accountId = randomUUID()
    const calendarId = randomUUID()
    await db.insert(googleAccounts).values({ id: accountId, email: 'range@example.com', label: 'range', refreshTokenEnc: 'private' })
    await db.insert(calendars).values({ id: calendarId, accountId, googleId: 'range', summary: 'Range', accessRole: 'owner', selected: true })
    await db.insert(events).values({ id: randomUUID(), calendarId, googleId: 'range-all-day', status: 'confirmed', summary: 'Trip', allDay: true, startAt: new Date('2026-10-31T00:00:00Z'), endAt: new Date('2026-11-02T00:00:00Z') })
    await db.insert(events).values({ id: randomUUID(), calendarId, googleId: 'range-timed', status: 'confirmed', summary: 'Overnight', allDay: false, startAt: new Date('2026-11-01T06:30:00Z'), endAt: new Date('2026-11-01T08:30:00Z') })
    const taskId = randomUUID()
    const projectId = randomUUID()
    const blockId = randomUUID()
    const window = { startAt: new Date('2026-11-01T06:30:00Z'), endAt: new Date('2026-11-01T08:30:00Z') }
    await db.insert(tasks).values({ id: taskId, categoryId: 'inbox', title: 'Range task', durationMinutes: 120, priority: 'medium', deadlineType: 'none' })
    await db.insert(placements).values({ id: randomUUID(), taskId, computedAt: new Date(), pinned: false, ...window })
    await db.insert(projects).values({ id: projectId, name: 'Range project' })
    await db.insert(projectPlacements).values({ id: randomUUID(), projectId, weekOf: '2026-11-01', computedAt: new Date(), ...window })
    await db.insert(routineBlocks).values({ id: blockId, name: 'Range commitment', days: [0], start: '01:00', end: '02:00', allows: [] })
    await db.insert(routineOccurrences).values({ id: randomUUID(), blockId, computedAt: new Date(), ...window })
    await db.insert(dayOverrides).values({ date: '2026-11-01', kind: 'home', note: 'DST day' })
    const select = vi.spyOn(db, 'select')
    let result: { days: Record<string, unknown>[], timeZone: string }
    try {
      result = await data('get_range', { startDate: '2026-10-31', endDate: '2026-11-02' })
      expect(select).toHaveBeenCalledTimes(6)
    } finally { select.mockRestore() }
    expect(result.timeZone).toBe(LA)
    expect(result.days).toHaveLength(3)
    for (const day of result.days) expect(day).toEqual(await data('get_agenda', { date: day.date }))
    expect(result.days[1]?.start).toBe('2026-11-01T07:00:00.000Z')
    expect(result.days[1]?.end).toBe('2026-11-02T08:00:00.000Z')
    expect((result.days[1]?.events as unknown[]).length).toBeGreaterThan(0)
    for (const day of result.days.slice(0, 2)) {
      expect(day.taskBlocks).toEqual(expect.arrayContaining([expect.objectContaining({ taskId, appUrl: `florida://tasks/${taskId}` })]))
      expect(day.projectTime).toEqual(expect.arrayContaining([expect.objectContaining({ projectId })]))
      expect(day.commitments).toEqual(expect.arrayContaining([expect.objectContaining({ name: 'Range commitment' })]))
    }
    expect(result.days[1]?.dayOverride).toEqual({ kind: 'home', note: 'DST day' })
    expect(result.days[2]?.taskBlocks).not.toEqual(expect.arrayContaining([expect.objectContaining({ taskId })]))
    expect((await data<{ days: unknown[] }>('get_range', { startDate: '2026-12-01', endDate: '2026-12-31' })).days).toHaveLength(31)
    for (const endDate of ['2026-10-30', '2026-12-01']) {
      expect((await call('get_range', { startDate: '2026-10-31', endDate })).content[0]?.text).toContain('at most 31 days')
    }
    expect((await call('get_range', { startDate: '2026-02-30', endDate: '2026-03-01' })).isError).toBe(true)
  })

  it('lists, searches, and restores tombstones idempotently with scheduling and links', async () => {
    const older = randomUUID()
    const newer = randomUUID()
    await db.insert(tasks).values([
      { id: older, categoryId: 'inbox', title: 'Deleted unique', durationMinutes: 30, priority: 'medium', deadlineType: 'none', deletedAt: new Date('2026-11-01T00:00:00Z') },
      { id: newer, categoryId: 'inbox', title: 'Other', durationMinutes: 30, priority: 'medium', deadlineType: 'none', notes: 'DELETED UNIQUE', deletedAt: new Date('2026-11-02T00:00:00Z') },
    ])
    const deleted = await data<{ tasks: { id: string, appUrl: string }[] }>('list_deleted_tasks', { query: ' deleted unique ', limit: 1 })
    expect(deleted.tasks).toEqual([expect.objectContaining({ id: newer, appUrl: `florida://tasks/${newer}` })])
    for (let i = 0; i < 2; i++) {
      const restored = await data<{ task: TaskView & { appUrl: string, deletedAt: null }, scheduling: object }>('restore_task', { id: newer })
      expect(restored.task).toMatchObject({ id: newer, deletedAt: null, appUrl: `florida://tasks/${newer}`, placements: expect.any(Array) })
      expect(restored.scheduling).toMatchObject({ unscheduled: expect.any(Array), late: expect.any(Array) })
    }
    expect((await data<{ tasks: { id: string }[] }>('list_deleted_tasks', { query: 'deleted unique' })).tasks.map((task) => task.id)).toEqual([older])
    expect((await call('restore_task', { id: randomUUID() })).content[0]?.text).toContain('not found')
    expect((await call('list_deleted_tasks', { limit: 201 })).isError).toBe(true)
  })

  it('publishes restores through incremental sync even with a skewed application clock', async () => {
    const { task } = await data<{ task: TaskView }>('create_task', { categoryId: 'inbox', title: 'Sync restore' })
    await data('delete_task', { id: task.id })
    const response = await app.request('/api/sync', { headers })
    const { cursor } = await response.json() as { cursor: string }
    const NativeDate = Date
    const skewed = new NativeDate(cursor).getTime() - 60_000
    class ApplicationDate extends NativeDate {
      constructor(value?: string | number) { super(value ?? skewed) }
    }
    vi.stubGlobal('Date', ApplicationDate)
    try {
      await data('restore_task', { id: task.id })
      const incremental = await app.request(`/api/sync?since=${encodeURIComponent(cursor)}`, { headers })
      const body = await incremental.json() as { tasks: { id: string, deletedAt: string | null, appUrl?: string }[] }
      expect(body.tasks.find((row) => row.id === task.id)).toMatchObject({ id: task.id, deletedAt: null })
      expect(body.tasks.find((row) => row.id === task.id)).not.toHaveProperty('appUrl')
    } finally { vi.unstubAllGlobals() }
  })

  it('restores a task from a deleted category into Inbox, ready for subsequent edits', async () => {
    const categoryId = randomUUID()
    const category = await app.request(`/api/categories/${categoryId}`, { method: 'PUT', headers, body: JSON.stringify({ name: 'Temporary', scheduleId: 'work' }) })
    expect(category.status).toBe(200)
    const { task } = await data<{ task: TaskView }>('create_task', { categoryId, title: 'Orphan restore' })
    await data('delete_task', { id: task.id })
    expect((await app.request(`/api/categories/${categoryId}`, { method: 'DELETE', headers })).status).toBe(200)
    expect((await data<{ task: { categoryId: string } }>('restore_task', { id: task.id })).task.categoryId).toBe('inbox')
    expect((await data<{ task: TaskView }>('update_task', { id: task.id, title: 'Editable again' })).task.title).toBe('Editable again')
  })

  it('restores only one recurring occurrence without restarting its deleted series', async () => {
    const { task } = await data<{ task: TaskView }>('create_task', {
      categoryId: 'inbox', title: 'Recurring restore', recurrence: { frequency: 'day', interval: 1, timeZone: LA, startDate: '2026-11-10' },
    })
    await data('delete_task', { id: task.id })
    await data('restore_task', { id: task.id })
    const rows = (await data<{ tasks: TaskView[] }>('list_tasks', { query: 'Recurring restore' })).tasks
    expect(rows.map((row) => row.id)).toEqual([task.id])
    expect((await data<{ tasks: TaskView[] }>('list_deleted_tasks', { query: 'Recurring restore' })).tasks.length).toBeGreaterThan(0)
  })
})

describe('Wave 1A calendar and parser tools', () => {
  const sync = new FakeSync()
  const calendarId = randomUUID()
  const accountId = randomUUID()
  let original: Hono

  beforeAll(async () => {
    original = app
    app = createApp({ db, config, sync, reschedule: () => runScheduling(db, config) })
    await db.insert(googleAccounts).values({ id: accountId, email: 'mcp@example.com', label: 'mcp', refreshTokenEnc: 'SECRET_REFRESH', accessToken: 'SECRET_ACCESS' })
    await db.insert(calendars).values([
      { id: calendarId, accountId, googleId: 'mcp', summary: 'Writable', accessRole: 'writer', selected: true, syncToken: 'SECRET_SYNC', channelToken: 'SECRET_CHANNEL' },
      { id: `${calendarId}-reader`, accountId, googleId: 'reader', summary: 'Reader', accessRole: 'reader', selected: true },
      { id: `${calendarId}-off`, accountId, googleId: 'off', summary: 'Off', accessRole: 'owner', selected: false },
    ])
  })
  afterAll(() => { app = original })

  it('lists writable calendars without exposing account or sync credentials', async () => {
    const result = await data<{ accounts: unknown[], calendars: unknown[], writableCalendarIds: string[] }>('list_calendars')
    expect(JSON.stringify(result)).not.toContain('SECRET_')
    expect(result.writableCalendarIds).toContain(calendarId)
    expect(result.writableCalendarIds).not.toContain(`${calendarId}-reader`)
    expect(result.writableCalendarIds).not.toContain(`${calendarId}-off`)
  })

  it('creates, updates, overrides, syncs, and deletes events through shared write paths', async () => {
    const body = { calendarId, summary: 'MCP holiday', startAt: '2026-11-18T00:00:00Z', endAt: '2026-11-19T00:00:00Z', allDay: true }
    const created = await data<{ event: { id: string }, scheduling: object }>('upsert_event', body)
    const id = created.event.id
    expect(id).toMatch(/^[0-9a-f-]{36}$/)
    expect(sync.eventWrites.at(-1)?.method).toBe('insert')
    expect(created.scheduling).toMatchObject({ unscheduled: expect.any(Array), late: expect.any(Array) })
    expect((await data<{ event: { summary: string } }>('upsert_event', { ...body, id, summary: 'Updated' })).event.summary).toBe('Updated')
    expect(sync.eventWrites.at(-1)?.method).toBe('patch')
    for (const blocksDay of [true, false, null]) expect((await data<{ event: { blocksDay: boolean | null } }>('set_event_blocks_day', { id, blocksDay })).event.blocksDay).toBe(blocksDay)
    await data('sync_google_calendar')
    expect(sync.syncAllCalls).toBe(1)
    expect(await data('delete_event', { id })).toMatchObject({ deleted: id })
    await data('delete_event', { id })
    expect((await call('upsert_event', { ...body, id })).isError).toBe(true)
    expect((await call('set_event_blocks_day', { id, blocksDay: true })).isError).toBe(true)
    expect((await call('delete_event', { id: randomUUID() })).isError).toBe(true)
    for (const patch of [{ endAt: body.startAt }, { startAt: '2026-11-18T01:00:00Z' }, { id: 'invalid' }, { calendarId: `${calendarId}-reader` }]) expect((await call('upsert_event', { ...body, ...patch })).isError).toBe(true)
    sync.nextWriteError = new GoogleApiError(403, 'Google refused write')
    expect((await call('upsert_event', body)).isError).toBe(true)
  })

  it('exposes guest invitations with the same merge and omission semantics as HTTP', async () => {
    const body = { calendarId, summary: 'Guests', startAt: '2026-11-18T10:00:00Z', endAt: '2026-11-18T11:00:00Z', allDay: false }
    const { event } = await data<{ event: { id: string, googleId: string } }>('upsert_event', {
      ...body, attendees: [' ALICE@acme.com ', 'alice@acme.com'],
    })
    expect(sync.eventWrites.at(-1)?.body?.attendees).toEqual([{ email: 'alice@acme.com' }])
    const live = sync.googleEvents.get(event.googleId)!
    live.attendees = [
      { email: 'alice@acme.com', displayName: 'Alice', responseStatus: 'accepted' },
      { email: 'mcp@example.com', self: true, organizer: true, responseStatus: 'needsAction' },
    ]
    await data('upsert_event', { ...body, id: event.id, attendees: ['alice@acme.com', 'bob@acme.com'], responseStatus: 'tentative' })
    expect(sync.eventWrites.at(-1)?.body?.attendees).toEqual([
      { email: 'alice@acme.com', displayName: 'Alice', responseStatus: 'accepted' },
      { email: 'mcp@example.com', self: true, organizer: true, responseStatus: 'tentative' },
      { email: 'bob@acme.com' },
    ])
    await data('upsert_event', { ...body, id: event.id, summary: 'Omitted' })
    expect(sync.eventWrites.at(-1)?.body).toEqual({ summary: 'Omitted' })
    await data('upsert_event', { ...body, id: event.id, attendees: [] })
    expect(sync.eventWrites.at(-1)?.body?.attendees).toEqual([{ email: 'mcp@example.com', self: true, organizer: true, responseStatus: 'tentative' }])
    for (const attendees of [['invalid'], Array(51).fill('a@acme.com')]) {
      expect((await call('upsert_event', { ...body, attendees })).isError).toBe(true)
    }
  })

  it('turns a remotely deleted event into a tool error after rescheduling', async () => {
    const body = { calendarId, summary: 'Gone', startAt: '2026-11-18T10:00:00Z', endAt: '2026-11-18T11:00:00Z', allDay: false }
    const { event } = await data<{ event: { id: string } }>('upsert_event', body)
    expect((await call('set_event_blocks_day', { id: event.id, blocksDay: true })).isError).toBe(true)
    sync.nextWriteError = new GoogleApiError(410, 'Gone')
    expect((await call('upsert_event', { ...body, id: event.id, summary: 'Changed' })).isError).toBe(true)
    const [stored] = await db.select().from(events).where(eq(events.id, event.id))
    expect(stored?.deletedAt).not.toBeNull()
  })

  it('returns a clear AI error when unconfigured and drafts without writing with live context', async () => {
    expect((await call('parse_task', { text: 'Do something' })).content[0]?.text).toContain('ai is not configured')
    const draft = { title: 'Draft only' } as TaskDraft
    const parse = vi.fn(async (_text: string, _context: ParseTaskContext) => draft)
    const previous = app
    app = createApp({ db, config, sync, reschedule: () => runScheduling(db, config), ai: { parse } })
    try {
      const before = await db.select().from(tasks)
      expect(await data('parse_task', { text: '  Do something  ', now: '2026-11-16T10:00:00Z', timeZone: 'UTC' })).toEqual({ draft })
      expect(parse.mock.calls[0]?.[0]).toBe('Do something')
      expect(parse.mock.calls[0]?.[1]).toMatchObject({ now: new Date('2026-11-16T10:00:00Z'), timeZone: 'UTC', categories: expect.arrayContaining([expect.objectContaining({ id: 'inbox', examples: expect.any(Array) })]) })
      const active = await db.select().from(projects)
      expect(parse.mock.calls[0]?.[1].projects?.map((p) => p.id).sort()).toEqual(active.filter((p) => p.status === 'active' && p.deletedAt === null).map((p) => p.id).sort())
      await data('parse_task', { text: 'Defaults' })
      expect(parse.mock.calls[1]?.[1].timeZone).toBe(LA)
      expect(await db.select().from(tasks)).toEqual(before)
      expect((await call('parse_task', { text: '  ' })).isError).toBe(true)
    } finally { app = previous }
  })

  it('allows scheduler-only sync without Google configuration but refuses event writes clearly', async () => {
    const previous = app
    app = new Hono()
    const reschedule = vi.fn(() => runScheduling(db, config))
    mountMcp(app, { db, reschedule })
    try {
      await data('sync_google_calendar')
      expect(reschedule).toHaveBeenCalledOnce()
      expect((await call('delete_event', { id: randomUUID() })).content[0]?.text).toContain('sync is not configured')
    } finally { app = previous }
  })
})

describe('task tags and waiting follow-ups', () => {
  it('normalizes tags and supports combined tag, all-tags, and waiting filters', async () => {
    const title = 'Wave3 filter'
    const a = (await data<{ task: TaskView }>('create_task', { categoryId: 'work', title, tags: [' Client ', '', 'CLIENT', 'Approval'], waitingOn: ' Alice ' })).task
    const b = (await data<{ task: TaskView }>('create_task', { categoryId: 'work', title, tags: ['client'] })).task
    expect(a).toMatchObject({ tags: ['client', 'approval'], waitingOn: 'Alice', waitingUntil: null, placements: [] })
    const ids = async (filters: object) => (await data<{ tasks: TaskView[] }>('list_tasks', { query: title, ...filters })).tasks.map((t) => t.id).sort()
    expect(await ids({ tag: ' CLIENT ' })).toEqual([a.id, b.id].sort())
    expect(await ids({ tags: ['CLIENT', ' Approval ', 'client'] })).toEqual([a.id])
    expect(await ids({ tag: 'client', tags: ['approval'], waiting: true })).toEqual([a.id])
    expect(await ids({ waiting: false })).toEqual([b.id])
    expect(await ids({ tags: ['missing'] })).toEqual([])
    expect((await data<{ tasks: TaskView[] }>('list_tasks', { categoryId: 'work', query: title })).tasks.map((t) => t.id)).toContain(a.id)
    for (const tags of [Array.from({ length: 31 }, (_, i) => `tag-${i}`), ['x'.repeat(65)]]) {
      expect((await call('update_task', { id: a.id, tags })).isError).toBe(true)
    }
  })

  it('converts follow-up dates in the settings time zone, keeps ISO instants, clears pins, and resumes on clear', async () => {
    const created = (await data<{ task: TaskView & { pinnedStart: string | null } }>('create_task', {
      categoryId: 'work', title: 'Wave3 follow-up', waitingOn: ' Reply ', waitingUntil: '2026-11-10', pinnedStart: '2026-11-09T18:00:00Z',
    })).task
    expect(created.waitingUntil).toBe('2026-11-10T08:00:00.000Z')
    expect(created.pinnedStart).toBeNull()
    expect(created.placements.length).toBeGreaterThan(0)
    expect(created.placements.every((p) => p.startAt >= created.waitingUntil!)).toBe(true)
    const iso = '2026-11-11T12:34:00-08:00'
    expect((await data<{ task: TaskView }>('update_task', { id: created.id, waitingUntil: iso })).task.waitingUntil).toBe(new Date(iso).toISOString())
    const cleared = (await data<{ task: TaskView }>('update_task', { id: created.id, waitingOn: '  ' })).task
    expect(cleared).toMatchObject({ waitingOn: null, waitingUntil: null })
    expect(cleared.placements.some((p) => p.startAt < created.waitingUntil!)).toBe(true)
    for (const waitingUntil of ['2026-02-30', 'invalid', '2026-11-11T00:00:00']) {
      expect((await call('update_task', { id: created.id, waitingOn: 'Reply', waitingUntil })).isError).toBe(true)
    }
    expect((await call('create_task', { categoryId: 'work', title: 'Orphan follow-up', waitingUntil: '2026-11-10' })).isError).toBe(true)
    expect((await call('update_task', { id: created.id, waitingUntil: '2026-11-10' })).isError).toBe(true)
    const invalid = { id: created.id, waitingOn: null, waitingUntil: '2026-11-10' }
    for (const dryRun of [false, true]) {
      expect((await call('update_task', { ...invalid, dryRun })).isError).toBe(true)
      expect((await call('batch_update_tasks', { tasks: [invalid], dryRun })).isError).toBe(true)
      expect((await call('batch', { operations: [{ tool: 'update_task', arguments: invalid }], dryRun })).isError).toBe(true)
    }
  })

  it('supports tags and date follow-ups in every batch path and rolls previews back', async () => {
    const ids = [randomUUID(), randomUUID()]
    const inputs = ids.map((id) => ({ id, categoryId: 'work', title: 'Wave3 batch', tags: [' Batch ', 'batch'], waitingOn: ' Client ', waitingUntil: '2026-11-10' }))
    const before = await db.select().from(tasks)
    const beforeNotices = notices
    const preview = await data<{ results: { task: TaskView }[] }>('batch_create_tasks', { tasks: inputs, dryRun: true })
    expect(preview.results[0]?.task).toMatchObject({ tags: ['batch'], waitingOn: 'Client', waitingUntil: '2026-11-10T08:00:00.000Z' })
    expect(await db.select().from(tasks)).toEqual(before)
    expect(notices).toBe(beforeNotices)
    const single = await data<{ task: TaskView }>('create_task', { ...inputs[0], dryRun: true })
    expect(single.task.tags).toEqual(['batch'])
    expect(await db.select().from(tasks)).toEqual(before)
    await data('batch_create_tasks', { tasks: inputs })
    const updates = ids.map((id) => ({ id, tags: [' Updated '], waitingUntil: '2026-11-12' }))
    await data('batch_update_tasks', { tasks: updates, dryRun: true })
    expect((await data<{ task: TaskView }>('get_task', { id: ids[0] })).task.tags).toEqual(['batch'])
    const changed = await data<{ results: { task: TaskView }[] }>('batch_update_tasks', { tasks: updates })
    expect(changed.results[1]?.task).toMatchObject({ tags: ['updated'], waitingUntil: '2026-11-12T08:00:00.000Z' })
    const mixed = await data<{ results: { task: TaskView }[] }>('batch', { operations: [
      { tool: 'update_task', arguments: { id: ids[0], waitingOn: null } },
      { tool: 'create_task', arguments: { categoryId: 'work', title: 'Wave3 mixed', tags: [' Mixed '], waitingOn: 'Approval', waitingUntil: '2026-11-13' } },
    ] })
    expect(mixed.results[0]?.task).toMatchObject({ waitingOn: null, waitingUntil: null })
    expect(mixed.results[1]?.task).toMatchObject({ tags: ['mixed'], waitingUntil: '2026-11-13T08:00:00.000Z' })
  })
})

describe('tasks with a required day', () => {
  it('previews the same Saturday fallback as a committed write, and supports clearing the option', async () => {
    const id = randomUUID()
    const args = {
      id, categoryId: 'personal', title: 'Saturday task', dueAt: '2026-11-15T01:00:00.000Z',
      mustHappenOnDay: true, durationMinutes: 5,
    }
    const beforeNotices = notices
    const preview = await data<{ task: TaskView }>('create_task', { ...args, dryRun: true })
    expect(preview.task).toMatchObject({
      mustHappenOnDay: true,
      placements: [{ startAt: '2026-11-14T15:00:00.000Z', endAt: '2026-11-14T15:05:00.000Z', pinned: false }],
    })
    expect(await db.select().from(tasks).where(eq(tasks.id, id))).toEqual([])
    expect(notices).toBe(beforeNotices)
    const committed = await data<{ task: TaskView }>('create_task', args)
    expect(committed.task.placements).toEqual(preview.task.placements)
    expect(await data('get_task', { id })).toMatchObject({ task: { mustHappenOnDay: true } })
    expect(await data('update_task', { id, mustHappenOnDay: false })).toMatchObject({ task: { mustHappenOnDay: false } })
    expect((await call('update_task', { id, mustHappenOnDay: 'yes' })).isError).toBe(true)
  })
})
