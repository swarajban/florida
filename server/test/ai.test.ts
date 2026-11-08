import type { Hono } from 'hono'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { ClaudeError } from '../src/ai/claude.js'
import { ClaudeTaskParser, TASK_DRAFT_JSON_SCHEMA, buildPrompt } from '../src/ai/parse-task.js'
import type { ParseTaskContext, TaskDraft, TaskParser } from '../src/ai/parse-task.js'
import { createApp } from '../src/app.js'
import type { Config } from '../src/config.js'
import type { Db } from '../src/db/client.js'
import type { CalendarSyncService } from '../src/google/sync.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'

const NOW = new Date('2026-11-08T17:00:00Z') // Sunday 09:00 in Los Angeles
const ctx: ParseTaskContext = {
  now: NOW,
  timeZone: 'America/Los_Angeles',
  projects: [
    { id: 'inbox', name: 'Inbox' },
    { id: 'work-eng', name: 'Work engineering' },
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
  projectId: 'work-eng',
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
  it('states the local time, zone and project ids', () => {
    const { system, user } = buildPrompt('Write design doc 2h by fri', ctx)
    expect(user).toBe('Write design doc 2h by fri')
    expect(system).toContain('Current local time: 2026-11-08 09:00 (Sunday), time zone America/Los_Angeles')
    expect(system).toContain('current instant 2026-11-08T17:00:00.000Z')
    expect(system).toContain('- id "inbox": Inbox')
    expect(system).toContain('- id "work-eng": Work engineering')
  })

  it('says when there are no projects', () => {
    expect(buildPrompt('x', { ...ctx, projects: [] }).system).toContain('Projects:\n(none)')
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

  it('drops an unknown projectId and reconciles deadlineType with dueAt', async () => {
    const api = fakeApi({
      body: messageWith({ ...modelDraft, projectId: 'made-up', deadlineType: 'none' }),
    })
    const draft = await new ClaudeTaskParser(config, api.fetch).parse('x', ctx)
    expect(draft.projectId).toBeNull()
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

  it('passes live projects, the client clock and zone, and returns the draft', async () => {
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
    expect(seen[0]!.ctx.projects).toEqual([{ id: 'inbox', name: 'Inbox' }])
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
})
