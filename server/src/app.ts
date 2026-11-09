import { randomBytes, timingSafeEqual } from 'node:crypto'
import type { SchedulerResult } from '@florida/scheduler'
import { and, eq, getTableColumns, gt, isNotNull, isNull, or } from 'drizzle-orm'
import type { PgColumn } from 'drizzle-orm/pg-core'
import { Hono } from 'hono'
import type { MiddlewareHandler } from 'hono'
import { html } from 'hono/html'
import { streamSSE } from 'hono/streaming'
import { HTTPException } from 'hono/http-exception'
import { ZodError, z } from 'zod'
import { ClaudeError } from './ai/claude.js'
import type { TaskParser } from './ai/parse-task.js'
import type { CategorySuggester } from './ai/suggest-category.js'
import { ChangeBus } from './changes.js'
import type { Config } from './config.js'
import type { Db } from './db/client.js'
import { INBOX_CATEGORY_ID, SETTINGS_ID, categoriesWithExamples, defaultTimeZone, scheduleExists } from './db/queries.js'
import {
  calendars,
  events,
  googleAccounts,
  optionalPlacements,
  placements,
  categories,
  routineBlocks,
  schedules,
  settings,
  tasks,
  unscheduled,
} from './db/schema.js'
import type { GoogleAccountRow } from './db/schema.js'
import { eventBody, softDeleteEvent, upsertEvent } from './events.js'
import { GoogleApiError, GoogleTokenError, authorizationUrl, exchangeCode } from './google/client.js'
import type { CalendarSyncService } from './google/sync.js'
import { mountMcp } from './mcp.js'
import {
  lockTaskRecurrences,
  moveRecurringTaskCategory,
  patchTask,
  softDeleteTask,
  taskBody,
  taskContext,
  taskPatch,
  upsertTask,
} from './tasks.js'
import { badRequest, clock, isoInstant, notFound, timeZone } from './validation.js'

export interface AppDeps {
  db: Db
  config: Config
  sync: CalendarSyncService
  reschedule: () => Promise<SchedulerResult>
  /** Receives a notice after every scheduler run the app triggers; streamed by `/api/events`. */
  changes?: ChangeBus
  /** Natural-language task parsing (Claude). When absent, `/api/ai/parse-task` answers 503. */
  ai?: TaskParser
  /** Category suggestions (Claude). When absent, `/api/ai/suggest-category` answers 503. */
  categorySuggester?: CategorySuggester
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

const categoryArea = z.enum(['work', 'personal'])

const categoryBody = z.object({
  name: z.string().min(1),
  color: z.string().nullish(),
  area: categoryArea.nullish(),
  scheduleId: z.string().min(1),
  sortOrder: z.number().int().nullish(),
})

const routineBlockBody = z
  .object({
    name: z.string().min(1),
    days: z.array(z.number().int().min(0).max(6)).min(1),
    start: clock,
    end: clock,
    /** Empty means the block is shown but nothing is scheduled in it (a gym slot, say). */
    allows: z.array(taskContext),
    /** Suggested, never planned (an evening). Omitted by clients that predate it: the stored value stays. */
    optional: z.boolean().optional(),
  })
  .refine((b) => b.start < b.end, 'end must be after start')

const settingsBody = z.object({ timeZone })

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

const suggestCategoryBody = z.object({
  title: z.string().trim().min(1).max(2000),
  notes: z.string().max(10_000).nullish(),
})

const parseTaskBody = z.object({
  text: z.string().trim().min(1).max(2000),
  /** Client's current time; defaults to the server clock. */
  now: isoInstant.optional(),
  /** Client's time zone; defaults to the routine's zone (settings), then UTC. */
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
    if (err instanceof GoogleApiError) {
      console.error(`[google] ${c.req.method} ${c.req.path} failed:`, err.message)
      return c.json({ error: err.message }, googleStatus(err))
    }
    console.error(`[http] ${c.req.method} ${c.req.path} failed:`, err)
    return c.json({ error: 'internal server error' }, 500)
  })

  app.get('/health', (c) => c.json({ ok: true }))

  // Google delivers calendar push notifications only to a domain verified in Search Console; the
  // HTML-tag method looks for this meta tag on the site root.
  app.get('/', (c) => {
    const verification = config.GOOGLE_SITE_VERIFICATION
    return c.html(html`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Florida</title>
${verification === undefined ? '' : html`<meta name="google-site-verification" content="${verification}">`}
</head>
<body>Florida sync server. Apps use <code>/api</code>, agents use <code>/mcp</code>.</body>
</html>`)
  })

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

    const routineBlockRows = await db.select().from(routineBlocks).where(changedAfter(routineBlocks.updatedAt))
    const scheduleRows = await db.select().from(schedules).where(changedAfter(schedules.updatedAt))
    const categoryRows = await db.select().from(categories).where(changedAfter(categories.updatedAt))
    const taskRows = await db.select().from(tasks).where(changedAfter(tasks.updatedAt))
    // Events of deselected calendars stay server-side; their tombstones still go out so clients drop them.
    const eventRows = await db
      .select(getTableColumns(events))
      .from(events)
      .innerJoin(calendars, eq(events.calendarId, calendars.id))
      .where(and(changedAfter(events.updatedAt), or(eq(calendars.selected, true), isNotNull(events.deletedAt))))
    // Small tables without tombstones: always sent in full so clients can replace them wholesale.
    const placementRows = await db.select().from(placements)
    const optionalPlacementRows = await db.select().from(optionalPlacements)
    const unscheduledRows = await db.select().from(unscheduled)
    const accountRows = await db.select(publicAccountColumns).from(googleAccounts)
    const calendarRows = await db.select(publicCalendarColumns).from(calendars)
    // One row, never deleted; null until the database is seeded.
    const [settingsRow] = await db.select().from(settings)

    return c.json({
      cursor: cursor.toISOString(),
      settings: settingsRow ?? null,
      routineBlocks: routineBlockRows,
      schedules: scheduleRows,
      categories: categoryRows,
      tasks: taskRows,
      events: eventRows,
      placements: placementRows,
      optionalPlacements: optionalPlacementRows,
      unscheduled: unscheduledRows,
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

  // Single rows exactly as /api/sync sends them, tombstones included, so a client can resync one
  // row after the server rejected its write.
  app.get('/api/tasks/:id', async (c) => {
    const id = c.req.param('id')
    const [task] = await db.select().from(tasks).where(eq(tasks.id, id))
    if (task === undefined) throw notFound(`task ${id}`)
    return c.json(task)
  })

  app.get('/api/categories/:id', async (c) => {
    const id = c.req.param('id')
    const [category] = await db.select().from(categories).where(eq(categories.id, id))
    if (category === undefined) throw notFound(`category ${id}`)
    return c.json(category)
  })

  app.get('/api/routine-blocks/:id', async (c) => {
    const id = c.req.param('id')
    const [block] = await db.select().from(routineBlocks).where(eq(routineBlocks.id, id))
    if (block === undefined) throw notFound(`routine block ${id}`)
    return c.json(block)
  })

  app.get('/api/schedules/:id', async (c) => {
    const id = c.req.param('id')
    const [schedule] = await db.select().from(schedules).where(eq(schedules.id, id))
    if (schedule === undefined) throw notFound(`schedule ${id}`)
    return c.json(schedule)
  })

  app.get('/api/events/:id', async (c) => {
    const id = c.req.param('id')
    const [event] = await db.select().from(events).where(eq(events.id, id))
    if (event === undefined) throw notFound(`event ${id}`)
    return c.json(event)
  })

  app.put('/api/tasks/:id', async (c) => {
    const task = await upsertTask(db, c.req.param('id'), taskBody.parse(await c.req.json()))
    const scheduling = await reschedule()
    return c.json({ task, scheduling })
  })

  app.patch('/api/tasks/:id', async (c) => {
    const task = await patchTask(db, c.req.param('id'), taskPatch.parse(await c.req.json()))
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
    if (id === INBOX_CATEGORY_ID) {
      const [inbox] = await db.select({ name: categories.name }).from(categories).where(eq(categories.id, INBOX_CATEGORY_ID))
      if (inbox !== undefined && inbox.name !== body.name) throw badRequest('the inbox category cannot be renamed')
    }
    const fields = {
      name: body.name,
      color: body.color ?? null,
      // Older shipped clients omit area (undefined is left out of the insert and the update, so
      // the stored value survives a rename, recolor or reorder); null explicitly clears it.
      area: body.area,
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

  // Tasks never outlive their category: they move to the permanent inbox first, so the scheduler
  // keeps placing them and clients see them change category through `updatedAt`.
  app.delete('/api/categories/:id', async (c) => {
    const id = c.req.param('id')
    if (id === INBOX_CATEGORY_ID) throw badRequest('the inbox category cannot be deleted')
    const now = new Date()
    const deleted = await db.transaction(async (tx) => {
      await lockTaskRecurrences(tx)
      const rows = await tx
        .update(categories)
        .set({ deletedAt: now, updatedAt: now })
        .where(eq(categories.id, id))
        .returning({ id: categories.id, scheduleId: categories.scheduleId })
      const [row] = rows
      if (row === undefined) return false
      // A database that was never seeded has no inbox yet; create it on the deleted category's
      // schedule rather than orphan the tasks.
      await tx
        .insert(categories)
        .values({ id: INBOX_CATEGORY_ID, name: 'Inbox', scheduleId: row.scheduleId, sortOrder: 0, updatedAt: now })
        .onConflictDoNothing({ target: categories.id })
      await tx
        .update(tasks)
        .set({ categoryId: INBOX_CATEGORY_ID, updatedAt: now })
        .where(and(eq(tasks.categoryId, id), isNull(tasks.deletedAt)))
      await moveRecurringTaskCategory(tx, id, INBOX_CATEGORY_ID, now)
      return true
    })
    if (!deleted) throw notFound(`category ${id}`)
    const scheduling = await reschedule()
    return c.json({ scheduling })
  })

  // ---- Routine ----------------------------------------------------------------------------------

  app.put('/api/routine-blocks/:id', async (c) => {
    const id = c.req.param('id')
    const body = routineBlockBody.parse(await c.req.json())
    const fields = { ...body, updatedAt: new Date(), deletedAt: null }
    const [routineBlock] = await db
      .insert(routineBlocks)
      .values({ id, ...fields })
      .onConflictDoUpdate({ target: routineBlocks.id, set: fields })
      .returning()
    const scheduling = await reschedule()
    return c.json({ routineBlock, scheduling })
  })

  app.delete('/api/routine-blocks/:id', async (c) => {
    const id = c.req.param('id')
    const now = new Date()
    const deleted = await db
      .update(routineBlocks)
      .set({ deletedAt: now, updatedAt: now })
      .where(eq(routineBlocks.id, id))
      .returning({ id: routineBlocks.id })
    if (deleted.length === 0) throw notFound(`routine block ${id}`)
    const scheduling = await reschedule()
    return c.json({ scheduling })
  })

  app.put('/api/settings', async (c) => {
    const body = settingsBody.parse(await c.req.json())
    const fields = { timeZone: body.timeZone, updatedAt: new Date() }
    const [row] = await db
      .insert(settings)
      .values({ id: SETTINGS_ID, ...fields })
      .onConflictDoUpdate({ target: settings.id, set: fields })
      .returning()
    const scheduling = await reschedule()
    return c.json({ settings: row, scheduling })
  })

  // ---- Schedules (superseded by the routine; kept for shipped clients) --------------------------

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

  // ---- Calendar events (written through to Google) ----------------------------------------------

  // An unknown id creates the event in `calendarId`; a live row is patched with what changed (an
  // RSVP re-sends the attendee list); a tombstone is 404. The reply holds Google's copy as a later
  // sync would store it. Google's refusals pass through (see `googleStatus`) and leave the row
  // untouched, except that an event Google has deleted since the last sync is tombstoned here, so
  // the client's refetch after the 404 finds the tombstone and drops its optimistic copy.
  app.put('/api/events/:id', async (c) => {
    const event = await upsertEvent(db, sync, c.req.param('id'), eventBody.parse(await c.req.json()))
    const scheduling = await reschedule()
    if (event.deletedAt !== null) throw notFound(`event ${event.id}`)
    return c.json({ event, scheduling })
  })

  app.delete('/api/events/:id', async (c) => {
    await softDeleteEvent(db, sync, c.req.param('id'))
    const scheduling = await reschedule()
    return c.json({ scheduling })
  })

  // ---- AI ---------------------------------------------------------------------------------------

  // Turns free text into a task draft. The client reviews it and then PUTs the task itself, so a
  // slow or wrong model answer never blocks or corrupts the local-first write path.
  app.post('/api/ai/parse-task', async (c) => {
    if (deps.ai === undefined) throw aiNotConfigured()
    const body = parseTaskBody.parse(await c.req.json())
    const draft = await deps.ai.parse(body.text, {
      now: body.now === undefined ? new Date() : new Date(body.now),
      timeZone: body.timeZone ?? (await defaultTimeZone(db)),
      categories: await categoriesWithExamples(db),
    })
    return c.json({ draft })
  })

  // Suggests where an already-titled task belongs. The inbox is where unfiled tasks wait, so it
  // is never offered.
  app.post('/api/ai/suggest-category', async (c) => {
    if (deps.categorySuggester === undefined) throw aiNotConfigured()
    const body = suggestCategoryBody.parse(await c.req.json())
    const options = (await categoriesWithExamples(db)).filter((p) => p.id !== INBOX_CATEGORY_ID)
    const suggestion = await deps.categorySuggester.suggest({ title: body.title, notes: body.notes ?? null }, options)
    return c.json({ categoryId: suggestion.categoryId, rationale: suggestion.rationale })
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

  // Deselecting tombstones the calendar's events so clients drop them. Selecting forgets the sync
  // token and re-downloads the calendar in the background, so every event comes back with a fresh
  // `updatedAt` that since-based sync picks up.
  app.patch('/api/calendars/:id', async (c) => {
    const id = c.req.param('id')
    const body = calendarPatch.parse(await c.req.json())
    const now = new Date()
    const calendar = await db.transaction(async (tx) => {
      const [row] = await tx
        .update(calendars)
        .set(body.selected ? { selected: true, syncToken: null, updatedAt: now } : { selected: false, updatedAt: now })
        .where(eq(calendars.id, id))
        .returning({ id: calendars.id, googleId: calendars.googleId, selected: calendars.selected })
      if (row !== undefined && !body.selected) {
        await tx
          .update(events)
          .set({ deletedAt: now, updatedAt: now })
          .where(and(eq(events.calendarId, id), isNull(events.deletedAt)))
      }
      return row
    })
    if (calendar === undefined) throw notFound(`calendar ${id}`)
    const scheduling = await reschedule()
    if (body.selected) void runCalendarSync(id)
    return c.json({ calendar, scheduling })
  })

  app.post('/api/google/sync', async (c) => {
    await sync.syncAll()
    return c.json(await reschedule())
  })

  // Full re-download of every selected calendar: rewrites every event row (and bumps `updatedAt`),
  // e.g. to backfill columns added after the rows were first synced.
  app.post('/api/google/resync', async (c) => {
    await db.update(calendars).set({ syncToken: null, updatedAt: new Date() }).where(eq(calendars.selected, true))
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
    void runAccountSync(account)
    return c.html(
      page(
        `Connected <strong>${escapeHtml(account.email)}</strong> as <code>${escapeHtml(account.label)}</code>. ` +
          'Its calendars are syncing in the background and appear in the apps as each one finishes. You can close this tab.',
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
      // A deselected calendar's channel can still fire until it expires; its events stay tombstoned.
      if (calendar === undefined || !calendar.selected) return
      await sync.syncCalendar(calendar)
      await reschedule()
    } catch (err) {
      console.error(`[webhook] sync of calendar ${calendarId} failed:`, err)
    }
  }

  /** First sync of a just-connected account: minutes of work, so it runs after the OAuth page is sent. */
  async function runAccountSync(account: GoogleAccountRow): Promise<void> {
    try {
      await sync.syncAccount(account)
      await reschedule()
    } catch (err) {
      console.error(`[google] initial sync of ${account.email} failed:`, err)
    }
  }

  return app
}

function aiNotConfigured(): HTTPException {
  return new HTTPException(503, { message: 'ai is not configured (set ANTHROPIC_API_KEY)' })
}

/**
 * How a Google failure reaches the client. A 400, 403 or 404/410 from the Calendar API is Google's
 * final word on that write: the client drops it and resyncs the row. Everything else (401, 429,
 * 5xx, a refresh token Google no longer honours) is between this server and Google, so the client
 * keeps the write and retries later.
 */
function googleStatus(err: GoogleApiError): 400 | 403 | 404 | 502 {
  if (err instanceof GoogleTokenError) return 502
  if (err.status === 400) return 400
  if (err.status === 403) return 403
  if (err.status === 404 || err.status === 410) return 404
  return 502
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
