import type { Hono } from 'hono'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
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
import { loadConfig } from '../src/config.js'
import type { Config } from '../src/config.js'
import { tasks } from '../src/db/schema.js'
import type { Db } from '../src/db/client.js'
import type { CalendarSyncService } from '../src/google/sync.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'

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
  const reschedule = () => Promise.resolve({ placements: [], unscheduled: [], late: [] })
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
  const reschedule = () => Promise.resolve({ placements: [], unscheduled: [], late: [] })
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
