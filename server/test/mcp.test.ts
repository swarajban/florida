import { dateFromDayNumber, dayNumber, localDate, weekdayOf, zonedToUtc } from '@florida/scheduler'
import type { LocalDate } from '@florida/scheduler'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { eq } from 'drizzle-orm'
import type { Hono } from 'hono'
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import { createApp } from '../src/app.js'
import { ChangeBus } from '../src/changes.js'
import type { Db } from '../src/db/client.js'
import { briefs, calendars, events, googleAccounts, tasks } from '../src/db/schema.js'
import { runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
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
  app = createApp({ db, config, sync: new FakeSync(), reschedule: () => runScheduling(db, config), changes })
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
      'clear_day',
      'complete_task',
      'create_project',
      'create_task',
      'delete_project',
      'delete_task',
      'get_agenda',
      'get_brief',
      'get_task',
      'list_categories',
      'list_projects',
      'list_tasks',
      'run_scheduler',
      'set_day',
      'update_project',
      'update_task',
    ])
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

describe('task tools', () => {
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
