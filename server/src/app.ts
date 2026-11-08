import { randomBytes, timingSafeEqual } from 'node:crypto'
import type { SchedulerResult } from '@florida/scheduler'
import { eq, gt, isNull } from 'drizzle-orm'
import type { PgColumn } from 'drizzle-orm/pg-core'
import { Hono } from 'hono'
import type { MiddlewareHandler } from 'hono'
import { streamSSE } from 'hono/streaming'
import { HTTPException } from 'hono/http-exception'
import { ZodError, z } from 'zod'
import { ClaudeError } from './ai/claude.js'
import type { TaskParser } from './ai/parse-task.js'
import { ChangeBus } from './changes.js'
import type { Config } from './config.js'
import type { Db } from './db/client.js'
import { defaultTimeZone, scheduleExists } from './db/queries.js'
import { calendars, events, googleAccounts, placements, categories, schedules, tasks } from './db/schema.js'
import { authorizationUrl, exchangeCode } from './google/client.js'
import type { CalendarSyncService } from './google/sync.js'
import { mountMcp } from './mcp.js'
import { softDeleteTask, taskBody, upsertTask } from './tasks.js'
import { badRequest, clock, isoInstant, notFound, timeZone } from './validation.js'

export interface AppDeps {
  db: Db
  config: Config
  sync: CalendarSyncService
  reschedule: () => Promise<SchedulerResult>
  /** Receives a notice after every scheduler run the app triggers; streamed by `/api/events`. */
  changes?: ChangeBus
  /** Natural-language task parsing (Claude). When absent, `/api/ai/*` answers 503. */
  ai?: TaskParser
  /** Delay before a webhook-triggered calendar sync runs; pings within it coalesce. Default 2 s. */
  webhookDebounceMs?: number
  /** Interval between SSE keep-alive comments. Default 25 s. */
  sseHeartbeatMs?: number
}

/** Columns of `google_accounts` that may leave the server (never the tokens). */
const publicAccountColumns = {
  id: googleAccounts.id,
  email: googleAccounts.email,
  label: googleAccounts.label,
  createdAt: googleAccounts.createdAt,
  updatedAt: googleAccounts.updatedAt,
}

/** Columns of `calendars` that clients need; sync tokens and channel secrets stay server-side. */
const publicCalendarColumns = {
  id: calendars.id,
  accountId: calendars.accountId,
  googleId: calendars.googleId,
  summary: calendars.summary,
  color: calendars.color,
  accessRole: calendars.accessRole,
  selected: calendars.selected,
  lastSyncedAt: calendars.lastSyncedAt,
  channelExpiresAt: calendars.channelExpiresAt,
  updatedAt: calendars.updatedAt,
}

const OAUTH_STATE_TTL = 10 * 60_000
const LABEL_RE = /^[a-z][a-z0-9-]{0,31}$/

const categoryBody = z.object({
  name: z.string().min(1),
  color: z.string().nullish(),
  scheduleId: z.string().min(1),
  sortOrder: z.number().int().nullish(),
})

const scheduleBody = z.object({
  name: z.string().min(1),
  timeZone,
  windows: z
    .array(
      z
        .object({
          days: z.array(z.number().int().min(0).max(6)).min(1),
          start: clock,
          end: clock,
        })
        .refine((w) => w.start < w.end, 'end must be after start'),
    )
    .min(1),
})

const calendarPatch = z.object({ selected: z.boolean() })

const parseTaskBody = z.object({
  text: z.string().trim().min(1).max(2000),
  /** Client's current time; defaults to the server clock. */
  now: isoInstant.optional(),
  /** Client's time zone; defaults to the first live schedule's zone, then UTC. */
  timeZone: timeZone.optional(),
})

export function createApp(deps: AppDeps): Hono {
  const { db, config, sync } = deps
  const changes = deps.changes ?? new ChangeBus()
  const webhookDebounceMs = deps.webhookDebounceMs ?? 2_000
  const sseHeartbeatMs = deps.sseHeartbeatMs ?? 25_000
  const reschedule = async (): Promise<SchedulerResult> => {
    const result = await deps.reschedule()
    changes.publish()
    return result
  }
  const oauth = {
    clientId: config.GOOGLE_CLIENT_ID,
    clientSecret: config.GOOGLE_CLIENT_SECRET,
    redirectUri: `${config.PUBLIC_URL}/auth/google/callback`,
  }
  const oauthStates = new Map<string, { label: string; expiresAt: number }>()
  const pendingSyncs = new Map<string, NodeJS.Timeout>()

  const app = new Hono()

  app.onError((err, c) => {
    if (err instanceof ZodError) return c.json({ error: 'validation failed', issues: err.issues }, 400)
    if (err instanceof HTTPException) return c.json({ error: err.message }, err.status)
    if (err instanceof ClaudeError) {
      console.error(`[ai] ${c.req.method} ${c.req.path} failed:`, err.message)
      return c.json({ error: `ai request failed: ${err.message}` }, 502)
    }
    console.error(`[http] ${c.req.method} ${c.req.path} failed:`, err)
    return c.json({ error: 'internal server error' }, 500)
  })

  app.get('/health', (c) => c.json({ ok: true }))

  const requireToken: MiddlewareHandler = async (c, next) => {
    const header = c.req.header('authorization') ?? ''
    const token = header.startsWith('Bearer ') ? header.slice('Bearer '.length) : ''
    if (token === '' || !safeEqual(token, config.API_TOKEN)) return c.json({ error: 'unauthorized' }, 401)
    await next()
  }
  app.use('/api/*', requireToken)
  app.use('/mcp', requireToken)

  // Model Context Protocol endpoint for agents; the same token, the same store, the same scheduler.
  mountMcp(app, { db, reschedule })

  // ---- Sync -------------------------------------------------------------------------------------

  app.get('/api/sync', async (c) => {
    const sinceIso = isoInstant.optional().parse(c.req.query('since'))
    const since = sinceIso === undefined ? undefined : new Date(sinceIso)
    const cursor = new Date()
    const changedAfter = (column: PgColumn) => (since === undefined ? undefined : gt(column, since))

    const scheduleRows = await db.select().from(schedules).where(changedAfter(schedules.updatedAt))
    const categoryRows = await db.select().from(categories).where(changedAfter(categories.updatedAt))
    const taskRows = await db.select().from(tasks).where(changedAfter(tasks.updatedAt))
    const eventRows = await db.select().from(events).where(changedAfter(events.updatedAt))
    // Small tables without tombstones: always sent in full so clients can replace them wholesale.
    const placementRows = await db.select().from(placements)
    const accountRows = await db.select(publicAccountColumns).from(googleAccounts)
    const calendarRows = await db.select(publicCalendarColumns).from(calendars)

    return c.json({
      cursor: cursor.toISOString(),
      schedules: scheduleRows,
      categories: categoryRows,
      tasks: taskRows,
      events: eventRows,
      placements: placementRows,
      accounts: accountRows,
      calendars: calendarRows,
    })
  })

  // Server-sent events: one `changed` event per scheduler run or calendar sync. Clients react by
  // calling GET /api/sync with their stored cursor. Keep-alive comments defeat idle proxy timeouts.
  app.get('/api/events', (c) =>
    streamSSE(c, async (stream) => {
      const aborted = new Promise<void>((resolve) => stream.onAbort(resolve))
      await stream.writeSSE({ event: 'connected', data: JSON.stringify({ at: new Date().toISOString() }) })
      const unsubscribe = changes.subscribe((notice) => {
        stream.writeSSE({ event: 'changed', data: JSON.stringify(notice) }).catch(() => {})
      })
      const heartbeat = setInterval(() => stream.write(': ping\n\n').catch(() => {}), sseHeartbeatMs)
      heartbeat.unref()
      try {
        await aborted
      } finally {
        unsubscribe()
        clearInterval(heartbeat)
      }
    }),
  )

  // ---- Tasks ------------------------------------------------------------------------------------

  app.put('/api/tasks/:id', async (c) => {
    const task = await upsertTask(db, c.req.param('id'), taskBody.parse(await c.req.json()))
    const scheduling = await reschedule()
    return c.json({ task, scheduling })
  })

  app.delete('/api/tasks/:id', async (c) => {
    await softDeleteTask(db, c.req.param('id'))
    const scheduling = await reschedule()
    return c.json({ scheduling })
  })

  // ---- Categories ---------------------------------------------------------------------------------

  app.put('/api/categories/:id', async (c) => {
    const id = c.req.param('id')
    const body = categoryBody.parse(await c.req.json())
    if (!(await scheduleExists(db, body.scheduleId))) throw badRequest(`unknown scheduleId ${body.scheduleId}`)
    const fields = {
      name: body.name,
      color: body.color ?? null,
      scheduleId: body.scheduleId,
      sortOrder: body.sortOrder ?? 0,
      updatedAt: new Date(),
      deletedAt: null,
    }
    const [category] = await db
      .insert(categories)
      .values({ id, ...fields })
      .onConflictDoUpdate({ target: categories.id, set: fields })
      .returning()
    const scheduling = await reschedule()
    return c.json({ category, scheduling })
  })

  app.delete('/api/categories/:id', async (c) => {
    const id = c.req.param('id')
    const now = new Date()
    const deleted = await db
      .update(categories)
      .set({ deletedAt: now, updatedAt: now })
      .where(eq(categories.id, id))
      .returning({ id: categories.id })
    if (deleted.length === 0) throw notFound(`category ${id}`)
    const scheduling = await reschedule()
    return c.json({ scheduling })
  })

  // ---- Schedules --------------------------------------------------------------------------------

  app.put('/api/schedules/:id', async (c) => {
    const id = c.req.param('id')
    const body = scheduleBody.parse(await c.req.json())
    const fields = {
      name: body.name,
      timeZone: body.timeZone,
      windows: body.windows,
      updatedAt: new Date(),
      deletedAt: null,
    }
    const [schedule] = await db
      .insert(schedules)
      .values({ id, ...fields })
      .onConflictDoUpdate({ target: schedules.id, set: fields })
      .returning()
    const scheduling = await reschedule()
    return c.json({ schedule, scheduling })
  })

  app.delete('/api/schedules/:id', async (c) => {
    const id = c.req.param('id')
    const now = new Date()
    const deleted = await db
      .update(schedules)
      .set({ deletedAt: now, updatedAt: now })
      .where(eq(schedules.id, id))
      .returning({ id: schedules.id })
    if (deleted.length === 0) throw notFound(`schedule ${id}`)
    const scheduling = await reschedule()
    return c.json({ scheduling })
  })

  app.post('/api/schedule/run', async (c) => c.json(await reschedule()))

  // ---- AI ---------------------------------------------------------------------------------------

  // Turns free text into a task draft. The client reviews it and then PUTs the task itself, so a
  // slow or wrong model answer never blocks or corrupts the local-first write path.
  app.post('/api/ai/parse-task', async (c) => {
    if (deps.ai === undefined) throw new HTTPException(503, { message: 'ai is not configured (set ANTHROPIC_API_KEY)' })
    const body = parseTaskBody.parse(await c.req.json())
    const categoryRows = await db
      .select({ id: categories.id, name: categories.name })
      .from(categories)
      .where(isNull(categories.deletedAt))
      .orderBy(categories.sortOrder, categories.name)
    const draft = await deps.ai.parse(body.text, {
      now: body.now === undefined ? new Date() : new Date(body.now),
      timeZone: body.timeZone ?? (await defaultTimeZone(db)),
      categories: categoryRows,
    })
    return c.json({ draft })
  })

  // ---- Google -----------------------------------------------------------------------------------

  app.get('/api/google/accounts', async (c) => {
    const accountRows = await db.select(publicAccountColumns).from(googleAccounts)
    const calendarRows = await db.select(publicCalendarColumns).from(calendars)
    const accounts = accountRows.map((account) => ({
      ...account,
      calendars: calendarRows.filter((cal) => cal.accountId === account.id),
    }))
    return c.json({ accounts })
  })

  app.patch('/api/calendars/:id', async (c) => {
    const id = c.req.param('id')
    const body = calendarPatch.parse(await c.req.json())
    const [calendar] = await db
      .update(calendars)
      .set({ selected: body.selected, updatedAt: new Date() })
      .where(eq(calendars.id, id))
      .returning({ id: calendars.id, googleId: calendars.googleId, selected: calendars.selected })
    if (calendar === undefined) throw notFound(`calendar ${id}`)
    const scheduling = await reschedule()
    return c.json({ calendar, scheduling })
  })

  app.post('/api/google/sync', async (c) => {
    await sync.syncAll()
    return c.json(await reschedule())
  })

  // ---- OAuth (browser flow, protected by the API token in the query string) ---------------------

  app.get('/auth/google/start', (c) => {
    const key = c.req.query('key') ?? ''
    if (key === '' || !safeEqual(key, config.API_TOKEN)) return c.json({ error: 'unauthorized' }, 401)
    const label = c.req.query('label') ?? ''
    if (!LABEL_RE.test(label)) throw badRequest('label must match /^[a-z][a-z0-9-]{0,31}$/')

    const now = Date.now()
    for (const [state, entry] of oauthStates) if (entry.expiresAt <= now) oauthStates.delete(state)
    const state = randomBytes(16).toString('hex')
    oauthStates.set(state, { label, expiresAt: now + OAUTH_STATE_TTL })
    return c.redirect(authorizationUrl(oauth, state))
  })

  app.get('/auth/google/callback', async (c) => {
    const googleError = c.req.query('error')
    if (googleError !== undefined) return c.html(page(`Google returned an error: ${escapeHtml(googleError)}`), 400)
    const code = c.req.query('code')
    const state = c.req.query('state')
    const entry = state === undefined ? undefined : oauthStates.get(state)
    if (code === undefined || state === undefined || entry === undefined || entry.expiresAt <= Date.now()) {
      return c.html(page('This sign-in link is invalid or has expired. Start again from /auth/google/start.'), 400)
    }
    oauthStates.delete(state)

    const tokens = await exchangeCode(oauth, code)
    const account = await sync.connectAccount(entry.label, tokens)
    await reschedule()
    return c.html(
      page(
        `Connected <strong>${escapeHtml(account.email)}</strong> as <code>${escapeHtml(account.label)}</code>. You can close this tab.`,
      ),
    )
  })

  // ---- Google push notifications ----------------------------------------------------------------

  app.post('/webhooks/google', async (c) => {
    const channelId = c.req.header('x-goog-channel-id')
    const channelToken = c.req.header('x-goog-channel-token')
    const state = c.req.header('x-goog-resource-state')
    if (channelId === undefined || state === undefined || state === 'sync') return c.body(null, 200)

    const [calendar] = await db
      .select({ id: calendars.id, channelToken: calendars.channelToken })
      .from(calendars)
      .where(eq(calendars.channelId, channelId))
      .limit(1)
    if (
      calendar === undefined ||
      calendar.channelToken === null ||
      channelToken === undefined ||
      !safeEqual(channelToken, calendar.channelToken)
    ) {
      console.warn(`[webhook] ignoring notification for channel ${channelId}: unknown channel or bad token`)
      return c.body(null, 200)
    }
    queueCalendarSync(calendar.id)
    return c.body(null, 200)
  })

  function queueCalendarSync(calendarId: string): void {
    const existing = pendingSyncs.get(calendarId)
    if (existing !== undefined) clearTimeout(existing)
    const timer = setTimeout(() => {
      pendingSyncs.delete(calendarId)
      void runCalendarSync(calendarId)
    }, webhookDebounceMs)
    timer.unref()
    pendingSyncs.set(calendarId, timer)
  }

  async function runCalendarSync(calendarId: string): Promise<void> {
    try {
      const [calendar] = await db.select().from(calendars).where(eq(calendars.id, calendarId)).limit(1)
      if (calendar === undefined) return
      await sync.syncCalendar(calendar)
      await reschedule()
    } catch (err) {
      console.error(`[webhook] sync of calendar ${calendarId} failed:`, err)
    }
  }

  return app
}

function safeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a)
  const right = Buffer.from(b)
  return left.length === right.length && timingSafeEqual(left, right)
}

function page(body: string): string {
  return (
    '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Florida</title>' +
    '<meta name="viewport" content="width=device-width, initial-scale=1"></head>' +
    '<body style="font: 16px system-ui, sans-serif; margin: 3rem auto; max-width: 32rem; padding: 0 1rem">' +
    `<h1>Florida</h1><p>${body}</p></body></html>`
  )
}

function escapeHtml(s: string): string {
  const map: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }
  return s.replace(/[&<>"']/g, (ch) => map[ch] ?? ch)
}
