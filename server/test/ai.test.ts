import type { Hono } from 'hono'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { isoDate, localDate } from '@florida/scheduler'
import {
  BRIEF_JSON_SCHEMA,
  ClaudeBriefWriter,
  DAILY_SYSTEM,
  EXPLAIN_SYSTEM,
  EXPLANATION_JSON_SCHEMA,
  WEEKLY_SYSTEM,
} from '../src/ai/brief.js'
import type { BriefWriter, PlacementExplainer } from '../src/ai/brief.js'
import { ClaudeError } from '../src/ai/claude.js'
import { ClaudeTaskParser, TASK_DRAFT_JSON_SCHEMA, buildPrompt } from '../src/ai/parse-task.js'
import type { ParseTaskContext, TaskDraft, TaskParser } from '../src/ai/parse-task.js'
import {
  CATEGORY_SUGGESTION_JSON_SCHEMA,
  ClaudeCategorySuggester,
  buildSuggestPrompt,
} from '../src/ai/suggest-category.js'
import type { CategorySuggester } from '../src/ai/suggest-category.js'
import { createApp } from '../src/app.js'
import { briefJob, dailyFacts, ensureBriefs, explainFacts, generateBrief, latestBriefs, weeklyFacts } from '../src/briefs.js'
import { loadConfig } from '../src/config.js'
import type { Config } from '../src/config.js'
import { dayOverrides, projects, tasks } from '../src/db/schema.js'
import type { Db } from '../src/db/client.js'
import type { CalendarSyncService } from '../src/google/sync.js'
import { runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'
import { FakeSync, testConfig } from './fixtures.js'

const NOW = new Date('2026-11-08T17:00:00Z') // Sunday 09:00 in Los Angeles
const ctx: ParseTaskContext = {
  now: NOW,
  timeZone: 'America/Los_Angeles',
  categories: [
    { id: 'inbox', name: 'Inbox', examples: [] },
    { id: 'work-eng', name: 'Work engineering', examples: ['Fix flaky CI', 'Review "auth" PR'] },
  ],
}

const modelDraft: TaskDraft = {
  title: 'Write design doc',
  notes: null,
  durationMinutes: 120,
  minChunkMinutes: null,
  priority: 'high',
  deadlineType: 'soft',
  dueAt: '2026-11-13T17:00:00-08:00',
  startAt: null,
  pinnedStart: null,
  categoryId: 'work-eng',
  context: 'computer',
  projectId: null,
  attention: null,
  rationale: 'Friday deadline, two hours, high priority, engineering work.',
}

/** Scripted Anthropic API: records the request and answers with the given body. */
function fakeApi(
  reply: { status?: number; body: unknown } | Error,
): { fetch: (input: string, init: RequestInit) => Promise<Response>; calls: { url: string; init: RequestInit }[] } {
  const calls: { url: string; init: RequestInit }[] = []
  return {
    calls,
    fetch: async (url, init) => {
      calls.push({ url, init })
      if (reply instanceof Error) throw reply
      const body = typeof reply.body === 'string' ? reply.body : JSON.stringify(reply.body)
      return new Response(body, { status: reply.status ?? 200, headers: { 'content-type': 'application/json' } })
    },
  }
}

const messageWith = (json: unknown) => ({
  id: 'msg_1',
  type: 'message',
  role: 'assistant',
  content: [{ type: 'text', text: typeof json === 'string' ? json : JSON.stringify(json) }],
  stop_reason: 'end_turn',
})

describe('buildPrompt', () => {
  it('states the local time, zone and category ids', () => {
    const { system, user } = buildPrompt('Write design doc 2h by fri', ctx)
    expect(user).toBe('Write design doc 2h by fri')
    expect(system).toContain('Current local time: 2026-11-08 09:00 (Sunday), time zone America/Los_Angeles')
    expect(system).toContain('current instant 2026-11-08T17:00:00.000Z')
    expect(system).toContain('- id "inbox": Inbox\n- id "work-eng"')
    expect(system).toContain('- id "work-eng": Work engineering\n  recent tasks: "Fix flaky CI", "Review \\"auth\\" PR"')
  })

  it('says when there are no categories', () => {
    expect(buildPrompt('x', { ...ctx, categories: [] }).system).toContain('Categories:\n(none)')
  })
})

describe('config', () => {
  it('defaults the model to Claude Sonnet 5.5', () => {
    const config = loadConfig({
      DATABASE_URL: 'postgres://x',
      API_TOKEN: 'test-token-0123456789abcdef',
      TOKEN_ENCRYPTION_KEY: '00'.repeat(32),
      GOOGLE_CLIENT_ID: 'id',
      GOOGLE_CLIENT_SECRET: 'secret',
      PUBLIC_URL: 'https://florida.test',
    })
    expect(config.ANTHROPIC_MODEL).toBe('claude-sonnet-5-5')
  })
})

describe('ClaudeTaskParser', () => {
  const config = { apiKey: 'sk-test', model: 'claude-test-1' }

  it('sends a structured-output request and returns the validated draft', async () => {
    const api = fakeApi({ body: messageWith(modelDraft) })
    const parser = new ClaudeTaskParser(config, api.fetch)
    const draft = await parser.parse('Write design doc 2h by fri !high #work', ctx)
    expect(draft).toEqual(modelDraft)

    expect(api.calls).toHaveLength(1)
    const call = api.calls[0]!
    expect(call.url).toBe('https://api.anthropic.com/v1/messages')
    expect(call.init.method).toBe('POST')
    const headers = call.init.headers as Record<string, string>
    expect(headers['x-api-key']).toBe('sk-test')
    expect(headers['anthropic-version']).toBe('2023-06-01')
    const body = JSON.parse(call.init.body as string) as {
      model: string
      max_tokens: number
      system: string
      messages: { role: string; content: string }[]
      output_config: { format: { type: string; schema: unknown } }
    }
    expect(body.model).toBe('claude-test-1')
    expect(body.messages).toEqual([{ role: 'user', content: 'Write design doc 2h by fri !high #work' }])
    expect(body.system).toContain('time zone America/Los_Angeles')
    expect(body.output_config.format.type).toBe('json_schema')
    expect(body.output_config.format.schema).toEqual(TASK_DRAFT_JSON_SCHEMA)
  })

  it('drops an unknown categoryId and reconciles deadlineType with dueAt', async () => {
    const api = fakeApi({
      body: messageWith({ ...modelDraft, categoryId: 'made-up', deadlineType: 'none' }),
    })
    const draft = await new ClaudeTaskParser(config, api.fetch).parse('x', ctx)
    expect(draft.categoryId).toBeNull()
    expect(draft.deadlineType).toBe('soft')

    const noDate = fakeApi({ body: messageWith({ ...modelDraft, dueAt: null, deadlineType: 'hard' }) })
    expect((await new ClaudeTaskParser(config, noDate.fetch).parse('x', ctx)).deadlineType).toBe('none')
  })

  it('offers the projects it was given, keeps one of them and drops any other projectId', async () => {
    const withProjects: ParseTaskContext = {
      ...ctx,
      projects: [
        { id: 'atlas', name: 'Atlas', parallel: true },
        { id: 'taxes', name: 'Taxes', parallel: false },
      ],
    }
    const known = fakeApi({ body: messageWith({ ...modelDraft, projectId: 'atlas', attention: 'shared' }) })
    expect(await new ClaudeTaskParser(config, known.fetch).parse('x', withProjects)).toMatchObject({ projectId: 'atlas', attention: 'shared' })
    const system = (JSON.parse(known.calls[0]!.init.body as string) as { system: string }).system
    expect(system).toContain('- id "atlas": Atlas (parallel: an agent does most of the work)')
    // A project that is not parallel is listed by name alone.
    expect(system.endsWith('- id "taxes": Taxes')).toBe(true)

    const unknown = fakeApi({ body: messageWith({ ...modelDraft, projectId: 'made-up', attention: 'full' }) })
    expect(await new ClaudeTaskParser(config, unknown.fetch).parse('x', withProjects)).toMatchObject({ projectId: null, attention: 'full' })
    // Without projects to choose from, none can be named.
    const none = fakeApi({ body: messageWith({ ...modelDraft, projectId: 'atlas' }) })
    expect((await new ClaudeTaskParser(config, none.fetch).parse('x', ctx)).projectId).toBeNull()
  })

  it('rejects a draft that violates the schema', async () => {
    const api = fakeApi({ body: messageWith({ ...modelDraft, priority: 'urgent', dueAt: 'friday' }) })
    await expect(new ClaudeTaskParser(config, api.fetch).parse('x', ctx)).rejects.toThrow(/priority|dueAt/)
  })

  it('wraps API failures in ClaudeError', async () => {
    const http = fakeApi({ status: 429, body: { error: { message: 'rate limited' } } })
    await expect(new ClaudeTaskParser(config, http.fetch).parse('x', ctx)).rejects.toMatchObject({
      name: 'ClaudeError',
      status: 429,
    })

    const notJson = fakeApi({ body: messageWith('not json at all') })
    await expect(new ClaudeTaskParser(config, notJson.fetch).parse('x', ctx)).rejects.toBeInstanceOf(ClaudeError)

    const network = fakeApi(new Error('ECONNRESET'))
    await expect(new ClaudeTaskParser(config, network.fetch).parse('x', ctx)).rejects.toThrow(/ECONNRESET/)
  })
})

describe('ClaudeCategorySuggester', () => {
  const config = { apiKey: 'sk-test', model: 'claude-test-1' }
  const options = [
    { id: 'work', name: 'Work', examples: ['Prep quarterly review', 'Reply to recruiter'] },
    { id: 'personal', name: 'Personal', examples: [] },
  ]

  it('lists the categories with their recent tasks and sends title and notes', () => {
    const { system, user } = buildSuggestPrompt({ title: 'Book dentist', notes: 'before December' }, options)
    expect(system).toContain('Categories:\n- id "work": Work\n  recent tasks: "Prep quarterly review", "Reply to recruiter"\n- id "personal": Personal')
    expect(user).toBe('Title: Book dentist\nNotes: before December')
    expect(buildSuggestPrompt({ title: 'Book dentist', notes: null }, options).user).toBe('Title: Book dentist')
  })

  it('sends a structured-output request and returns the suggestion', async () => {
    const api = fakeApi({ body: messageWith({ categoryId: 'personal', rationale: 'Health errands are personal.' }) })
    const suggestion = await new ClaudeCategorySuggester(config, api.fetch).suggest({ title: 'Book dentist', notes: null }, options)
    expect(suggestion).toEqual({ categoryId: 'personal', rationale: 'Health errands are personal.' })
    expect(api.calls).toHaveLength(1)
    const body = JSON.parse(api.calls[0]!.init.body as string) as {
      model: string
      messages: { role: string; content: string }[]
      output_config: { format: { type: string; schema: unknown } }
    }
    expect(body.model).toBe('claude-test-1')
    expect(body.messages).toEqual([{ role: 'user', content: 'Title: Book dentist' }])
    expect(body.output_config.format).toEqual({ type: 'json_schema', schema: CATEGORY_SUGGESTION_JSON_SCHEMA })
  })

  it('turns an id that was not offered, such as the inbox, into null', async () => {
    for (const categoryId of ['inbox', 'made-up']) {
      const api = fakeApi({ body: messageWith({ categoryId, rationale: 'r' }) })
      const suggestion = await new ClaudeCategorySuggester(config, api.fetch).suggest({ title: 'x', notes: null }, options)
      expect(suggestion).toEqual({ categoryId: null, rationale: 'r' })
    }
  })

  it('wraps API failures in ClaudeError and rejects malformed output', async () => {
    const http = fakeApi({ status: 500, body: { error: { message: 'boom' } } })
    await expect(new ClaudeCategorySuggester(config, http.fetch).suggest({ title: 'x', notes: null }, options)).rejects.toMatchObject({
      name: 'ClaudeError',
      status: 500,
    })
    const bad = fakeApi({ body: messageWith({ category: 'work' }) })
    await expect(new ClaudeCategorySuggester(config, bad.fetch).suggest({ title: 'x', notes: null }, options)).rejects.toThrow()
  })
})

describe('POST /api/ai/parse-task', () => {
  const config: Config = {
    DATABASE_URL: 'postgres://unused',
    API_TOKEN: 'test-token-0123456789abcdef',
    TOKEN_ENCRYPTION_KEY: '00'.repeat(32),
    GOOGLE_CLIENT_ID: 'client-id',
    GOOGLE_CLIENT_SECRET: 'client-secret',
    PUBLIC_URL: 'https://florida.test',
    PORT: 8080,
    HORIZON_DAYS: 28,
    ANTHROPIC_MODEL: 'claude-test-1',
  }
  const sync: CalendarSyncService = {
    connectAccount: () => Promise.reject(new Error('unused')),
    syncCalendar: () => Promise.resolve(),
    syncAll: () => Promise.resolve(),
    ensureAllWatches: () => Promise.resolve(),
    getEvent: () => Promise.reject(new Error('unused')),
    createEvent: () => Promise.reject(new Error('unused')),
    updateEvent: () => Promise.reject(new Error('unused')),
    deleteEvent: () => Promise.reject(new Error('unused')),
  }
  const reschedule = () => Promise.resolve({ placements: [], unscheduled: [], late: [], optional: [] })
  const AUTH = { authorization: `Bearer ${config.API_TOKEN}`, 'content-type': 'application/json' }

  let db: Db
  let close: () => Promise<void>
  let withAi: Hono
  let withoutAi: Hono
  const seen: { text: string; ctx: ParseTaskContext }[] = []
  const fakeParser: TaskParser = {
    parse: async (text, parseCtx) => {
      seen.push({ text, ctx: parseCtx })
      return modelDraft
    },
  }

  beforeAll(async () => {
    ;({ db, close } = await createTestDb())
    await seed(db)
    withAi = createApp({ db, config, sync, reschedule, ai: fakeParser })
    withoutAi = createApp({ db, config, sync, reschedule })
  })

  afterAll(() => close())

  it('answers 503 when no parser is configured', async () => {
    const res = await withoutAi.request('/api/ai/parse-task', {
      method: 'POST',
      headers: AUTH,
      body: JSON.stringify({ text: 'Call mom' }),
    })
    expect(res.status).toBe(503)
    expect(await res.json()).toEqual({ error: 'ai is not configured (set ANTHROPIC_API_KEY)' })
  })

  it('passes live categories, the client clock and zone, and returns the draft', async () => {
    const res = await withAi.request('/api/ai/parse-task', {
      method: 'POST',
      headers: AUTH,
      body: JSON.stringify({ text: 'Call mom 30m tomorrow', now: NOW.toISOString(), timeZone: 'Asia/Kolkata' }),
    })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ draft: modelDraft })
    expect(seen).toHaveLength(1)
    expect(seen[0]!.text).toBe('Call mom 30m tomorrow')
    expect(seen[0]!.ctx.now.toISOString()).toBe(NOW.toISOString())
    expect(seen[0]!.ctx.timeZone).toBe('Asia/Kolkata')
    expect(seen[0]!.ctx.categories).toEqual([
      { id: 'inbox', name: 'Inbox', examples: [] },
      { id: 'work', name: 'Work', examples: [] },
      { id: 'personal', name: 'Personal', examples: [] },
    ])
  })

  it("defaults the zone to the first schedule's and validates the body", async () => {
    const res = await withAi.request('/api/ai/parse-task', {
      method: 'POST',
      headers: AUTH,
      body: JSON.stringify({ text: 'Pay rent' }),
    })
    expect(res.status).toBe(200)
    expect(seen.at(-1)!.ctx.timeZone).toBe('America/Los_Angeles')

    const empty = await withAi.request('/api/ai/parse-task', { method: 'POST', headers: AUTH, body: JSON.stringify({ text: '  ' }) })
    expect(empty.status).toBe(400)
    const badZone = await withAi.request('/api/ai/parse-task', {
      method: 'POST',
      headers: AUTH,
      body: JSON.stringify({ text: 'x', timeZone: 'Mars/Olympus' }),
    })
    expect(badZone.status).toBe(400)
    expect((await withAi.request('/api/ai/parse-task', { method: 'POST', body: JSON.stringify({ text: 'x' }) })).status).toBe(401)
  })

  it('maps a model failure to 502', async () => {
    const failing = createApp({
      db,
      config,
      sync,
      reschedule,
      ai: { parse: () => Promise.reject(new ClaudeError('Anthropic API 529: overloaded', 529)) },
    })
    const res = await failing.request('/api/ai/parse-task', { method: 'POST', headers: AUTH, body: JSON.stringify({ text: 'x' }) })
    expect(res.status).toBe(502)
    expect(await res.json()).toEqual({ error: 'ai request failed: Anthropic API 529: overloaded' })
  })

  it('gives the parser up to 8 recent distinct titles per category, open tasks first, then recently completed', async () => {
    const t = (iso: string) => new Date(iso)
    const row = (id: string, categoryId: string, over: Partial<typeof tasks.$inferInsert> = {}) => ({
      id,
      categoryId,
      title: id,
      durationMinutes: 30,
      priority: 'medium' as const,
      deadlineType: 'none' as const,
      ...over,
    })
    await db.insert(tasks).values([
      row('open older', 'work', { createdAt: t('2026-10-01T00:00:00Z') }),
      row('open newer', 'work', { createdAt: t('2026-10-05T00:00:00Z') }),
      row('done long ago', 'work', { createdAt: t('2026-11-01T00:00:00Z'), completedAt: t('2026-11-02T00:00:00Z') }),
      row('done yesterday', 'work', { createdAt: t('2026-09-01T00:00:00Z'), completedAt: t('2026-11-07T00:00:00Z') }),
      // A recurring chore: the same title twice takes one slot, where its most recent instance ranks.
      row('rent oct', 'work', { title: 'Pay rent', createdAt: t('2026-10-01T00:00:00Z'), completedAt: t('2026-10-20T00:00:00Z') }),
      row('rent nov', 'work', { title: 'Pay rent', createdAt: t('2026-11-01T00:00:00Z'), completedAt: t('2026-11-05T00:00:00Z') }),
      row('deleted', 'work', { createdAt: t('2026-11-06T00:00:00Z'), deletedAt: t('2026-11-07T00:00:00Z') }),
      ...Array.from({ length: 10 }, (_, i) =>
        row(`chore ${i}`, 'personal', { createdAt: t('2026-10-01T00:00:00Z'), completedAt: new Date(Date.UTC(2026, 9, 10 + i)) }),
      ),
    ])
    const res = await withAi.request('/api/ai/parse-task', { method: 'POST', headers: AUTH, body: JSON.stringify({ text: 'x' }) })
    expect(res.status).toBe(200)
    expect(seen.at(-1)!.ctx.categories).toEqual([
      { id: 'inbox', name: 'Inbox', examples: [] },
      { id: 'work', name: 'Work', examples: ['open newer', 'open older', 'done yesterday', 'Pay rent', 'done long ago'] },
      {
        id: 'personal',
        name: 'Personal',
        examples: ['chore 9', 'chore 8', 'chore 7', 'chore 6', 'chore 5', 'chore 4', 'chore 3', 'chore 2'],
      },
    ])
  })

  it('gives the parser the active projects in their order, and no project that is waiting, done or deleted', async () => {
    expect(seen.at(-1)!.ctx.projects).toEqual([])
    await db.insert(projects).values([
      { id: 'p-billing', name: 'Billing', sortOrder: 2 },
      { id: 'p-atlas', name: 'Atlas', parallel: true, sortOrder: 1 },
      { id: 'p-agents', name: 'Agents', sortOrder: 1 },
      { id: 'p-garden', name: 'Garden', status: 'on_hold' },
      { id: 'p-idea', name: 'Idea', status: 'thinking' },
      { id: 'p-shipped', name: 'Shipped', status: 'done' },
      { id: 'p-gone', name: 'Gone', deletedAt: NOW },
    ])
    const res = await withAi.request('/api/ai/parse-task', { method: 'POST', headers: AUTH, body: JSON.stringify({ text: 'x' }) })
    expect(res.status).toBe(200)
    expect(seen.at(-1)!.ctx.projects).toEqual([
      { id: 'p-agents', name: 'Agents', parallel: false },
      { id: 'p-atlas', name: 'Atlas', parallel: true },
      { id: 'p-billing', name: 'Billing', parallel: false },
    ])
  })
})

describe('ClaudeBriefWriter', () => {
  const config = { apiKey: 'sk-test', model: 'claude-test-1' }
  interface Sent {
    system: string
    max_tokens: number
    messages: { role: string; content: string }[]
    output_config: { format: { type: string; schema: unknown } }
  }
  const sent = (api: ReturnType<typeof fakeApi>): Sent => JSON.parse(api.calls[0]!.init.body as string) as Sent

  it('sends the facts as JSON under the prompt of the brief\'s kind and returns the trimmed text', async () => {
    const facts = { date: '2026-11-09', plan: [{ title: 'Atlas migration', lane: 0 }] }
    const text = { headline: ' Two projects side by side this morning ', body: 'Atlas and Billing run together from 10.\nGym at 15:30.\n' }
    const daily = fakeApi({ body: messageWith(text) })
    expect(await new ClaudeBriefWriter(config, daily.fetch).write('daily', facts)).toEqual({
      headline: 'Two projects side by side this morning',
      body: 'Atlas and Billing run together from 10.\nGym at 15:30.',
    })
    expect(sent(daily).system).toBe(DAILY_SYSTEM)
    expect(sent(daily).messages).toEqual([{ role: 'user', content: JSON.stringify(facts) }])
    expect(sent(daily).output_config.format).toEqual({ type: 'json_schema', schema: BRIEF_JSON_SCHEMA })

    const weekly = fakeApi({ body: messageWith(text) })
    await new ClaudeBriefWriter(config, weekly.fetch).write('weekly', facts)
    expect(sent(weekly).system).toBe(WEEKLY_SYSTEM)
    expect(WEEKLY_SYSTEM).not.toBe(DAILY_SYSTEM)
  })

  it('explains a placement in a short answer', async () => {
    const api = fakeApi({ body: messageWith({ explanation: ' It follows the UPS return, which is due first. ' }) })
    expect(await new ClaudeBriefWriter(config, api.fetch).explain({ task: { title: 'Billing export' } })).toBe(
      'It follows the UPS return, which is due first.',
    )
    expect(sent(api).system).toBe(EXPLAIN_SYSTEM)
    expect(sent(api).max_tokens).toBe(400)
    expect(sent(api).messages).toEqual([{ role: 'user', content: JSON.stringify({ task: { title: 'Billing export' } }) }])
    expect(sent(api).output_config.format.schema).toEqual(EXPLANATION_JSON_SCHEMA)
  })

  it('wraps API failures in ClaudeError and rejects empty or malformed text', async () => {
    const down = fakeApi({ status: 529, body: { type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } } })
    await expect(new ClaudeBriefWriter(config, down.fetch).write('daily', {})).rejects.toBeInstanceOf(ClaudeError)
    await expect(new ClaudeBriefWriter(config, down.fetch).explain({})).rejects.toBeInstanceOf(ClaudeError)
    // A reply that does not fit is the model's failure (502), not a bad request (400).
    const blank = fakeApi({ body: messageWith({ headline: '  ', body: 'x' }) })
    await expect(new ClaudeBriefWriter(config, blank.fetch).write('daily', {})).rejects.toBeInstanceOf(ClaudeError)
    const wrongKey = fakeApi({ body: messageWith({ reason: 'because' }) })
    await expect(new ClaudeBriefWriter(config, wrongKey.fetch).explain({})).rejects.toBeInstanceOf(ClaudeError)
  })

  it('gives up on a model that never answers', async () => {
    const hung = (_url: string, init: RequestInit) =>
      new Promise<Response>((_resolve, reject) => init.signal?.addEventListener('abort', () => reject(init.signal?.reason)))
    await expect(new ClaudeBriefWriter({ ...config, timeoutMs: 20 }, hung).explain({})).rejects.toBeInstanceOf(ClaudeError)
  })
})

describe('briefs', () => {
  const MONDAY = new Date('2026-11-09T17:00:00Z') // 09:00 in Los Angeles
  let db: Db
  let close: () => Promise<void>
  const written: { kind: string; facts: { date?: string; weekOf?: string } }[] = []
  const writer: BriefWriter = {
    write: async (kind, facts) => {
      written.push({ kind, facts: facts as { date?: string; weekOf?: string } })
      return { headline: `${kind} ${written.length}`, body: 'Line one\nLine two' }
    },
  }

  beforeAll(async () => {
    ;({ db, close } = await createTestDb())
    await seed(db)
    await db.insert(projects).values([
      { id: 'atlas', name: 'Atlas', status: 'active', parallel: true, weeklyMinutes: 120, nextStep: 'Wire the lanes' },
      { id: 'billing', name: 'Billing', status: 'active', parallel: true },
      { id: 'garden', name: 'Garden', status: 'on_hold' },
    ])
    const task = { categoryId: 'work', durationMinutes: 60, priority: 'medium', deadlineType: 'none' } as const
    await db.insert(tasks).values([
      { ...task, id: 'a', title: 'Atlas migration', projectId: 'atlas' },
      { ...task, id: 'b', title: 'Billing export', projectId: 'billing' },
      // Due Thursday 17:00 Pacific.
      { ...task, id: 'c', title: 'Return UPS parcel', categoryId: 'personal', context: 'errand', deadlineType: 'hard', dueAt: new Date('2026-11-13T01:00:00Z') },
      { ...task, id: 'd', title: 'Shipped it', projectId: 'atlas', completedAt: new Date('2026-11-09T16:30:00Z'), completedMinutes: 60 },
      { ...task, id: 'e', title: 'Print badge', context: 'office' },
    ])
    await db.insert(dayOverrides).values({ date: '2026-11-12', kind: 'off', note: 'Dentist' })
    await runScheduling(db, { HORIZON_DAYS: 28 }, MONDAY)
  })

  afterAll(() => close())

  it('the daily facts are today\'s plan with its lanes, the gym and what is left of the day', async () => {
    expect(await dailyFacts(db, MONDAY)).toMatchObject({
      date: '2026-11-09',
      weekday: 'Monday',
      writtenAt: '09:00',
      day: 'home',
      // Thursday is off, so the week's other sessions are the office morning and Friday.
      gym: {
        today: [{ name: 'Gym', start: '15:30', end: '16:45' }],
        restOfWeek: ['Tue 2026-11-10 09:00', 'Fri 2026-11-13 15:30'],
        missedThisWeek: false,
      },
      meetings: [],
      plan: [
        { title: 'Return UPS parcel', deadline: 'hard', due: 'Thu 2026-11-12 17:00', start: '09:00', end: '10:00' },
        { title: 'Atlas migration', project: 'Atlas', start: '10:00', end: '11:00', lane: 0 },
        { title: 'Billing export', project: 'Billing', start: '10:00', end: '11:00', lane: 1 },
      ],
      // Atlas has its two hours this week: one finished task and one open one.
      projectTime: [],
      late: [],
      unscheduled: [],
      // 09:00–15:30 less the errand and the hour the two lanes share.
      freeMinutesToday: { computer: 270, errand: 270, home: 270, office: 0 },
    })
    // The office task waits for Tuesday, so it is not in Monday's plan.
    expect(JSON.stringify(await dailyFacts(db, MONDAY))).not.toContain('Print badge')
    expect(await dailyFacts(db, new Date('2026-11-12T17:00:00Z'))).toMatchObject({ day: 'off', dayNote: 'Dentist', gym: { today: [] }, plan: [] })
  })

  it('the weekly facts count time per project and say whether the week is over', async () => {
    const friday = await weeklyFacts(db, new Date('2026-11-13T22:00:00Z'))
    expect(friday).toMatchObject({
      weekOf: '2026-11-08',
      weekIsOver: false,
      projects: [
        { name: 'Atlas', parallel: true, weeklyBudgetMinutes: 120, minutesSpent: 60, tasksCompleted: 1, openTasks: 1, nextStep: 'Wire the lanes' },
        { name: 'Billing', weeklyBudgetMinutes: null, minutesSpent: 0, tasksCompleted: 0, openTasks: 1 },
      ],
      waiting: [{ name: 'Garden', status: 'on_hold' }],
      completed: { count: 1, titles: ['Shipped it'] },
      // Still open a day after it was due.
      late: [{ title: 'Return UPS parcel', due: 'Thu 2026-11-12 17:00' }],
    })
    // Written on Sunday evening, the review is of the week that just ended.
    expect(await weeklyFacts(db, new Date('2026-11-16T02:00:00Z'))).toMatchObject({ weekOf: '2026-11-08', weekIsOver: true, completed: { count: 1 } })
    // On Monday it is of the new week, where nothing is finished yet.
    expect(await weeklyFacts(db, new Date('2026-11-16T17:00:00Z'))).toMatchObject({ weekOf: '2026-11-15', weekIsOver: false, completed: { count: 0 } })
  })

  it('the facts behind a placement name what is planned ahead of the task and what runs beside it', async () => {
    expect(await explainFacts(db, 'b', MONDAY)).toMatchObject({
      now: 'Mon 2026-11-09 09:00',
      task: { title: 'Billing export', project: 'Billing', projectStatus: 'active', context: 'computer', attention: 'shared', durationMinutes: 60 },
      planned: [{ start: 'Mon 2026-11-09 10:00', end: '11:00', lane: 1 }],
      unscheduled: null,
      plannedAheadOfIt: { count: 1, first: [{ title: 'Return UPS parcel', deadline: 'hard' }] },
      runsBeside: ['Atlas migration'],
    })
    const office = await explainFacts(db, 'e', MONDAY)
    expect(office.routineHoursAllowingItsContext.map((b) => b.days)).toEqual([['Tuesday'], ['Wednesday']])
    expect(office.planned[0]?.start).toBe('Tue 2026-11-10 10:15')
    await expect(explainFacts(db, 'never-existed', MONDAY)).rejects.toThrow('task never-existed not found')
  })

  it('writes the daily brief once from 08:30 and the weekly review once on Sunday from 18:00', async () => {
    expect(await ensureBriefs(db, writer, new Date('2026-11-09T16:29:00Z'))).toEqual([])
    expect(await latestBriefs(db)).toEqual([])

    const morning = await ensureBriefs(db, writer, new Date('2026-11-09T16:30:00Z'))
    expect(morning).toMatchObject([{ kind: 'daily', date: '2026-11-09', headline: 'daily 1', body: 'Line one\nLine two' }])
    expect(await ensureBriefs(db, writer, new Date('2026-11-09T19:00:00Z'))).toEqual([])
    // Monday's weekday is not Sunday, however late it is.
    expect(await ensureBriefs(db, writer, new Date('2026-11-10T07:30:00Z'))).toEqual([])
    expect(written).toMatchObject([{ kind: 'daily', facts: { date: '2026-11-09' } }])

    // Sunday 17:59 Pacific: the day's brief is due, the review is not.
    const sunday = await ensureBriefs(db, writer, new Date('2026-11-16T01:59:00Z'))
    expect(sunday.map((b) => [b.kind, b.date])).toEqual([['daily', '2026-11-15']])
    const review = await ensureBriefs(db, writer, new Date('2026-11-16T02:00:00Z'))
    expect(review.map((b) => [b.kind, b.date])).toEqual([['weekly', '2026-11-08']])
    expect(written.at(-1)).toMatchObject({ kind: 'weekly', facts: { weekOf: '2026-11-08' } })
    expect(await ensureBriefs(db, writer, new Date('2026-11-16T03:00:00Z'))).toEqual([])
    expect(written).toHaveLength(3)

    // Asking again rewrites the same brief in place; sync sends the newest of each kind.
    const rewritten = await generateBrief(db, writer, 'daily', new Date('2026-11-16T04:00:00Z'))
    expect(rewritten).toMatchObject({ id: sunday[0]!.id, date: '2026-11-15', headline: 'daily 4', createdAt: sunday[0]!.createdAt })
    expect(rewritten.updatedAt.getTime()).toBeGreaterThan(sunday[0]!.updatedAt.getTime())
    expect((await latestBriefs(db)).map((b) => [b.kind, b.date, b.headline])).toEqual([
      ['daily', '2026-11-15', 'daily 4'],
      ['weekly', '2026-11-08', 'weekly 3'],
    ])
  })

  it('a review asked for during the week does not stand in for the one on Sunday', async () => {
    const fresh = await createTestDb()
    try {
      await seed(fresh.db)
      // Wednesday's review and the following Sunday's are filed under the same week.
      const midweek = await generateBrief(fresh.db, writer, 'weekly', new Date('2026-11-11T20:00:00Z'))
      expect(midweek.date).toBe('2026-11-08')
      const sunday = await ensureBriefs(fresh.db, writer, new Date('2026-11-16T02:05:00Z'))
      expect(sunday.map((b) => [b.kind, b.date])).toEqual([
        ['daily', '2026-11-15'],
        ['weekly', '2026-11-08'],
      ])
      expect(sunday[1]).toMatchObject({ id: midweek.id })
      expect(sunday[1]?.headline).not.toBe(midweek.headline)
      expect(await ensureBriefs(fresh.db, writer, new Date('2026-11-16T03:00:00Z'))).toEqual([])
    } finally {
      await fresh.close()
    }
  })

  it('waits an hour after a failed brief before asking the model again', async () => {
    const fresh = await createTestDb()
    try {
      await seed(fresh.db)
      let calls = 0
      const down: BriefWriter = {
        write: async () => {
          calls += 1
          throw new ClaudeError('Anthropic API 529', 529)
        },
      }
      const job = briefJob(fresh.db, down)
      await expect(job(new Date('2026-11-09T16:30:00Z'))).rejects.toBeInstanceOf(ClaudeError)
      expect(await job(new Date('2026-11-09T16:40:00Z'))).toEqual([])
      expect(await job(new Date('2026-11-09T17:29:00Z'))).toEqual([])
      expect(calls).toBe(1)
      await expect(job(new Date('2026-11-09T17:30:00Z'))).rejects.toBeInstanceOf(ClaudeError)
      expect(calls).toBe(2)
    } finally {
      await fresh.close()
    }
  })

  it('sends the model the ten longest-overdue tasks and how many there are', async () => {
    const fresh = await createTestDb()
    try {
      await seed(fresh.db)
      const overdue = Array.from({ length: 12 }, (_, i) => ({
        id: `late-${String(i).padStart(2, '0')}`,
        title: `Overdue ${i}`,
        categoryId: 'work',
        durationMinutes: 30,
        priority: 'medium' as const,
        deadlineType: 'hard' as const,
        // late-00 was due an hour before MONDAY, late-11 twelve hours before.
        dueAt: new Date(MONDAY.getTime() - (i + 1) * 3_600_000),
      }))
      await fresh.db.insert(tasks).values(overdue)
      for (const facts of [await dailyFacts(fresh.db, MONDAY), await weeklyFacts(fresh.db, MONDAY)]) {
        expect(facts.lateCount).toBe(12)
        expect(facts.late.map((t) => t.title)).toEqual([11, 10, 9, 8, 7, 6, 5, 4, 3, 2].map((i) => `Overdue ${i}`))
        expect(facts).toMatchObject({ unscheduled: [], unscheduledCount: 0 })
      }
    } finally {
      await fresh.close()
    }
  })
})

describe('POST /api/ai/brief and /api/ai/explain', () => {
  const AUTH = { authorization: `Bearer ${testConfig.API_TOKEN}`, 'content-type': 'application/json' }
  let db: Db
  let close: () => Promise<void>
  let app: Hono
  let without: Hono
  let failing: Hono
  const explained: { task: { title: string } }[] = []
  const writer: BriefWriter & PlacementExplainer = {
    write: async (kind) => ({ headline: `The ${kind} brief`, body: 'Line one\nLine two' }),
    explain: async (facts) => {
      explained.push(facts as { task: { title: string } })
      return 'It is the only thing planned.'
    },
  }
  const post = (target: Hono, path: string, body: unknown) => target.request(path, { method: 'POST', headers: AUTH, body: JSON.stringify(body) })

  beforeAll(async () => {
    ;({ db, close } = await createTestDb())
    await seed(db)
    await db.insert(tasks).values({ id: 't1', categoryId: 'work', title: 'Write the report', durationMinutes: 60, priority: 'medium', deadlineType: 'none' })
    const deps = { db, config: testConfig, sync: new FakeSync(), reschedule: () => runScheduling(db, testConfig) }
    await deps.reschedule()
    app = createApp({ ...deps, briefWriter: writer })
    without = createApp(deps)
    const broken = () => Promise.reject(new ClaudeError('overloaded'))
    failing = createApp({ ...deps, briefWriter: { write: broken, explain: broken } })
  })

  afterAll(() => close())

  it('answer 503 when AI is not configured and 502 when the model fails', async () => {
    for (const [path, body] of [['/api/ai/brief', { kind: 'daily' }], ['/api/ai/explain', { taskId: 't1' }]] as const) {
      const res = await post(without, path, body)
      expect(res.status).toBe(503)
      expect(await res.json()).toEqual({ error: 'ai is not configured (set ANTHROPIC_API_KEY)' })
      expect((await post(failing, path, body)).status).toBe(502)
    }
    const synced = await without.request('/api/sync', { headers: AUTH })
    expect(((await synced.json()) as { briefs: unknown[] }).briefs).toEqual([])
  })

  it('writes the brief asked for, stores it and sends it with every sync', async () => {
    expect((await post(app, '/api/ai/brief', { kind: 'monthly' })).status).toBe(400)
    expect((await post(app, '/api/ai/brief', {})).status).toBe(400)

    const res = await post(app, '/api/ai/brief', { kind: 'daily' })
    expect(res.status).toBe(200)
    const { brief } = (await res.json()) as { brief: { id: string; date: string } }
    expect(brief).toMatchObject({ kind: 'daily', headline: 'The daily brief', body: 'Line one\nLine two' })
    expect(brief.date).toBe(isoDate(localDate(Date.now(), 'America/Los_Angeles')))

    const weekly = await post(app, '/api/ai/brief', { kind: 'weekly' })
    expect(((await weekly.json()) as { brief: unknown }).brief).toMatchObject({ kind: 'weekly', headline: 'The weekly brief' })

    // A second request rewrites today's brief instead of adding one.
    const again = await post(app, '/api/ai/brief', { kind: 'daily' })
    expect(((await again.json()) as { brief: { id: string } }).brief.id).toBe(brief.id)
    const cursor = ((await (await app.request('/api/sync', { headers: AUTH })).json()) as { cursor: string }).cursor
    const synced = await app.request(`/api/sync?since=${encodeURIComponent(cursor)}`, { headers: AUTH })
    expect(((await synced.json()) as { briefs: { kind: string }[] }).briefs.map((b) => b.kind)).toEqual(['daily', 'weekly'])
  })

  it('explains where a task is planned, and answers 404 for a task it does not know', async () => {
    const res = await post(app, '/api/ai/explain', { taskId: 't1' })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ explanation: 'It is the only thing planned.' })
    expect(explained).toMatchObject([{ task: { title: 'Write the report' } }])
    expect((await post(app, '/api/ai/explain', { taskId: 'never-existed' })).status).toBe(404)
    expect((await post(app, '/api/ai/explain', {})).status).toBe(400)
  })
})

describe('POST /api/ai/suggest-category', () => {
  const sync: CalendarSyncService = {
    connectAccount: () => Promise.reject(new Error('unused')),
    syncAccount: () => Promise.resolve(),
    syncCalendar: () => Promise.resolve(),
    syncAll: () => Promise.resolve(),
    ensureAllWatches: () => Promise.resolve(),
    getEvent: () => Promise.reject(new Error('unused')),
    createEvent: () => Promise.reject(new Error('unused')),
    updateEvent: () => Promise.reject(new Error('unused')),
    deleteEvent: () => Promise.reject(new Error('unused')),
  }
  const reschedule = () => Promise.resolve({ placements: [], unscheduled: [], late: [], optional: [] })
  const config: Config = {
    DATABASE_URL: 'postgres://unused',
    API_TOKEN: 'test-token-0123456789abcdef',
    TOKEN_ENCRYPTION_KEY: '00'.repeat(32),
    GOOGLE_CLIENT_ID: 'client-id',
    GOOGLE_CLIENT_SECRET: 'client-secret',
    PUBLIC_URL: 'https://florida.test',
    PORT: 8080,
    HORIZON_DAYS: 28,
    ANTHROPIC_MODEL: 'claude-test-1',
  }
  const AUTH = { authorization: `Bearer ${config.API_TOKEN}`, 'content-type': 'application/json' }
  let db: Db
  let close: () => Promise<void>

  beforeAll(async () => {
    ;({ db, close } = await createTestDb())
    await seed(db)
    await db.insert(tasks).values([
      { id: 'w1', categoryId: 'work', title: 'Prep quarterly review', durationMinutes: 30, priority: 'medium', deadlineType: 'none' },
      { id: 'i1', categoryId: 'inbox', title: 'Unfiled thing', durationMinutes: 30, priority: 'medium', deadlineType: 'none' },
    ])
  })

  afterAll(() => close())

  const post = (app: Hono, body: unknown) =>
    app.request('/api/ai/suggest-category', { method: 'POST', headers: AUTH, body: JSON.stringify(body) })

  it('answers 503 when AI is not configured', async () => {
    const res = await post(createApp({ db, config, sync, reschedule }), { title: 'Book dentist' })
    expect(res.status).toBe(503)
    expect(await res.json()).toEqual({ error: 'ai is not configured (set ANTHROPIC_API_KEY)' })
  })

  it('offers every live category except the inbox, with examples, and returns the suggestion', async () => {
    const calls: { task: { title: string; notes: string | null }; categories: { id: string; examples: string[] }[] }[] = []
    const suggester: CategorySuggester = {
      suggest: async (task, categories) => {
        calls.push({ task, categories })
        return { categoryId: 'personal', rationale: 'Health errands are personal.' }
      },
    }
    const app = createApp({ db, config, sync, reschedule, categorySuggester: suggester })
    const res = await post(app, { title: 'Book dentist', notes: 'before December' })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ categoryId: 'personal', rationale: 'Health errands are personal.' })
    expect(calls).toEqual([
      {
        task: { title: 'Book dentist', notes: 'before December' },
        categories: [
          { id: 'work', name: 'Work', examples: ['Prep quarterly review'] },
          { id: 'personal', name: 'Personal', examples: [] },
        ],
      },
    ])
    expect((await post(app, { title: 'Book dentist' })).status).toBe(200)
    expect(calls.at(-1)!.task).toEqual({ title: 'Book dentist', notes: null })
  })

  it('never answers inbox even when the model says so, and validates the body', async () => {
    const api = fakeApi({ body: messageWith({ categoryId: 'inbox', rationale: 'Not sure.' }) })
    const app = createApp({
      db,
      config,
      sync,
      reschedule,
      categorySuggester: new ClaudeCategorySuggester({ apiKey: 'sk-test', model: 'claude-test-1' }, api.fetch),
    })
    const res = await post(app, { title: 'Something vague' })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ categoryId: null, rationale: 'Not sure.' })
    const system = (JSON.parse(api.calls[0]!.init.body as string) as { system: string }).system
    expect(system).not.toContain('"inbox"')

    expect((await post(app, { title: '  ' })).status).toBe(400)
    expect((await post(app, { notes: 'no title' })).status).toBe(400)
    expect(
      (await app.request('/api/ai/suggest-category', { method: 'POST', body: JSON.stringify({ title: 'x' }) })).status,
    ).toBe(401)
  })

  it('maps a model failure to 502', async () => {
    const app = createApp({
      db,
      config,
      sync,
      reschedule,
      categorySuggester: { suggest: () => Promise.reject(new ClaudeError('Anthropic API 529: overloaded', 529)) },
    })
    const res = await post(app, { title: 'x' })
    expect(res.status).toBe(502)
    expect(await res.json()).toEqual({ error: 'ai request failed: Anthropic API 529: overloaded' })
  })
})
