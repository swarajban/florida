import { randomUUID } from 'node:crypto'
import { dateFromDayNumber, dayNumber, findFreeSlots, localDate, zonedToUtc } from '@florida/scheduler'
import type { CatchUpBlock, LocalDate, SchedulerResult } from '@florida/scheduler'
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js'
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js'
import { and, asc, desc, eq, getTableColumns, gt, gte, ilike, inArray, isNotNull, isNull, lt, lte, or, sql } from 'drizzle-orm'
import type { Hono } from 'hono'
import { HTTPException } from 'hono/http-exception'
import { z } from 'zod'
import type { Db } from './db/client.js'
import { latestBriefs } from './briefs.js'
import { categoriesWithExamples, categoryListOrder, defaultTimeZone, INBOX_CATEGORY_ID } from './db/queries.js'
import { writeTimestamp } from './db/sync-clock.js'
import { syncCursor } from './db/sync-clock.js'
import { blockingEventInterval, localWeeks, runScheduling } from './scheduling.js'
import { placementChanges } from './schedule-changes.js'
import type { TaskParser } from './ai/parse-task.js'
import type { CalendarSyncService } from './google/sync.js'
import { GoogleApiError } from './google/client.js'
import { eventBody, setEventBlocksDay, softDeleteEvent, upsertEvent } from './events.js'
import {
  calendars,
  categories,
  dayOverrides,
  events,
  googleAccounts,
  placements,
  planSummary,
  projectPlacements,
  projects,
  routineBlocks,
  routineOccurrences,
  scheduleChanges,
  settings,
  unscheduled,
  tasks,
} from './db/schema.js'
import type { PlacementRow, TaskRow } from './db/schema.js'
import {
  clearDayOverride,
  dayOverrideBody,
  patchProject,
  projectBody,
  projectPatch,
  setDayOverride,
  softDeleteProject,
  upsertProject,
} from './projects.js'
import {
  completeTask,
  deadlineType,
  getTask,
  patchTask,
  priority,
  softDeleteTask,
  taskBody,
  taskContext,
  taskPatch,
  taskTags,
  taskPlacementVisible,
  upsertTask,
  lockTaskRecurrences,
} from './tasks.js'
import { laterCapture, laterId, laterPage, listLater, saveLater, setLaterState } from './later.js'
import { badRequest, calendarDate, formatCalendarDate, isoInstant, notFound, parseCalendarDate, timeZone } from './validation.js'

export interface McpDeps {
  db: Db
  /** Reruns the scheduler and notifies connected clients; the app's wrapper around `runScheduling`. */
  reschedule: (reason?: string) => Promise<SchedulerResult>
  sync?: CalendarSyncService
  ai?: TaskParser
  horizonDays?: number
  publish?: () => void
  laterChanged?: () => void
}

const SERVER_INFO = { name: 'florida', version: '0.1.0' }

const INSTRUCTIONS = [
  'Florida is a single-user task planner and calendar. Tasks belong to categories (each in the work or',
  'personal area) and carry a context: computer (anywhere with a laptop), errand (out and about), home',
  '(only at home) or office (only at the office). A weekly routine says which contexts fit which hours;',
  'after each change the scheduler places open tasks into routine blocks that allow their context,',
  'around calendar events, and returns placements: suggested work blocks, not calendar events. Call',
  'list_categories first to learn the category ids, get_agenda to see one day of calendar events plus',
  'planned task blocks, and list_tasks for what is open. Instants are ISO 8601 strings.',
  'Someday tasks stay off the plan and do not consume project budgets. Setting someday true clears',
  'the due date and pin but keeps the start date; setting a changed nonnull date with an omitted',
  'marker turns Someday off. To schedule again on the same date, explicitly send someday false.',
  'Tags are trimmed, lowercase, unique strings (up to 30, each up to 64 characters). waitingOn names',
  'a blocker and clears pins. With no waitingUntil the task is parked without scheduling warnings;',
  'a follow-up ISO instant or YYYY-MM-DD (midnight in the settings zone) allows scheduling from then.',
  'Clearing waitingOn clears waitingUntil too. list_tasks supports tag, all-tags and waiting filters.',
  'Projects are ongoing work bigger than one task, each thinking, active, on_hold or done; only tasks',
  'of active projects are scheduled, and a project with weeklyMinutes gets project time planned for',
  'what its tasks do not cover. Work that mostly runs itself (an agent does it) is shared attention:',
  'a parallel project, or a task with attention shared. Up to three shared blocks of different',
  'projects are planned side by side, each in its own lane. Call list_projects for project ids.',
  'The gym is a commitment in the routine that nothing is planned over. set_day marks one date as',
  'worked from home, at the office, or off, when it differs from its weekday; clear_day undoes it.',
  'get_brief returns the latest morning brief and weekly review.',
  'Tasks accept recurrence: daily, weekly (selected weekdays), or monthly (day of month), each with',
  'an interval, IANA timeZone, startDate, and optional inclusive endDate. Each occurrence completes',
  'independently. Editing a recurring task changes this and future unfinished occurrences; setting',
  'recurrence to null stops repeats and keeps this task. Deleting a recurring task stops the series',
  'and deletes this and future unfinished occurrences. Completed history is preserved.',
  'Set mustHappenOnDay to keep a flexible task on its repeat, due, or start date, even outside normal routine hours.',
  'Tasks can carry source: {url, title?, kind?}, or null to clear it. Only safe http, https and mailto',
  'URLs are accepted. Kind always follows the URL; a short title is derived without a network call',
  'when omitted. Omitting source on an edit keeps it.',
].join(' ')

const taskId = z.string().min(1).describe('Task id')
const dryRunInput = z.boolean().default(false).describe('Validate and compute the proposed plan in a rolled-back transaction; persist nothing and send no notifications')
const writeReason = (tool: string) => tool === 'set_day' || tool === 'clear_day' ? 'rescheduled due to day override' : tool.includes('project') ? 'rescheduled due to project update' : 'rescheduled due to task update'
const createTaskInput = z.object({
  ...taskBody.shape,
  waitingUntil: z.union([isoInstant, calendarDate]).nullish(),
  id: taskId.optional(),
  durationMinutes: z.number().int().min(1).default(30),
  priority: priority.default('medium'),
  deadlineType: deadlineType.optional(),
})
const updateTaskInput = taskPatch.extend({ waitingUntil: z.union([isoInstant, calendarDate]).nullish() })
const operation = z.discriminatedUnion('tool', [
  z.object({ tool: z.literal('create_task'), arguments: createTaskInput }),
  z.object({ tool: z.literal('update_task'), arguments: z.object({ id: taskId, ...updateTaskInput.shape }) }),
  z.object({ tool: z.literal('complete_task'), arguments: z.object({ id: taskId }) }),
  z.object({ tool: z.literal('delete_task'), arguments: z.object({ id: taskId }) }),
  z.object({ tool: z.literal('set_day'), arguments: z.object({ date: calendarDate, ...dayOverrideBody.shape }) }),
  z.object({ tool: z.literal('clear_day'), arguments: z.object({ date: calendarDate }) }),
  z.object({ tool: z.literal('update_project'), arguments: z.object({ id: taskId, ...projectPatch.shape }) }),
  z.object({ tool: z.literal('create_project'), arguments: z.object({ id: taskId.optional(), ...projectBody.shape }) }),
  z.object({ tool: z.literal('delete_project'), arguments: z.object({ id: taskId }) }),
])
type WriteOperation = z.infer<typeof operation>
const dueFilter = z.union([calendarDate, isoInstant])
const searchCondition = (query: string | undefined) => {
  const text = query?.trim()
  if (!text) return undefined
  const pattern = `%${text.replace(/[\\%_]/g, '\\$&')}%`
  return or(ilike(tasks.title, pattern), ilike(tasks.notes, pattern))
}

/**
 * Builds a fresh MCP server over the task store. Stateless transports need a new `McpServer` per
 * request, so this is called from `mountMcp` on every POST rather than once at startup.
 */
export function buildMcpServer(deps: McpDeps): McpServer {
  const { db, reschedule } = deps
  const laterChanged = deps.laterChanged ?? deps.publish
  const server = new McpServer(SERVER_INFO, { instructions: INSTRUCTIONS })

  server.registerTool('save_later', {
    description: 'Save an HTTP(S) link to Later, separate from tasks. Optionally provide a stable id for retries, a title, kind, or estimated minutes.',
    inputSchema: { ...laterCapture.shape, id: laterId.optional() },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, ({ id, ...body }) => run(async () => {
    const item = await saveLater(db, id ?? randomUUID(), { ...body, source: 'mcp' })
    laterChanged?.()
    return ok({ item })
  }))

  server.registerTool('list_later', {
    description: 'List Later items in oldest-first order. Defaults to the unread, unarchived queue.',
    inputSchema: laterPage.shape,
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, (page) => run(async () => ok({ items: await listLater(db, page) })))

  for (const [name, action, description] of [
    ['mark_later_read', 'read', 'Mark a Later item read.'],
    ['archive_later', 'archive', 'Move a Later item to Archived without deleting it.'],
  ] as const) {
    server.registerTool(name, {
      description,
      inputSchema: { id: laterId },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    }, ({ id }) => run(async () => {
      const item = await setLaterState(db, id, { action })
      laterChanged?.()
      return ok({ item })
    }))
  }

  server.registerTool('batch_create_tasks', {
    description: 'Atomically creates 1–100 tasks, then schedules once. dryRun rolls back all writes and returns the proposed plan and placement changes.',
    inputSchema: { tasks: z.array(createTaskInput).min(1).max(100), dryRun: dryRunInput },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, ({ tasks: bodies, dryRun }) => run(() => write(bodies.map((arguments_) => ({ tool: 'create_task', arguments: arguments_ })), dryRun)))

  server.registerTool('batch_update_tasks', {
    description: 'Atomically updates 1–100 tasks in order, then schedules once. Any invalid reference rolls back the whole batch.',
    inputSchema: { tasks: z.array(z.object({ id: taskId, ...updateTaskInput.shape })).min(1).max(100), dryRun: dryRunInput },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, ({ tasks: patches, dryRun }) => run(() => write(patches.map((arguments_) => ({ tool: 'update_task', arguments: arguments_ })), dryRun)))

  server.registerTool('batch', {
    description: 'Atomically applies 1–100 local write operations in order and schedules once. No Google/network writes. Results match operation order; errors roll back all writes.',
    inputSchema: { operations: z.array(operation).min(1).max(100), dryRun: dryRunInput },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  }, ({ operations, dryRun }) => run(() => write(operations, dryRun)))

  server.registerTool('list_changes', {
    description: 'Changed task/project snapshots and a 30-day placement/unscheduled journal since an exclusive timestamp. Follow nextCursor with the original since until hasMore is false, then save the returned since watermark.',
    inputSchema: { since: isoInstant, cursor: z.object({ tasks: z.object({ at: isoInstant, id: z.string() }).optional(), projects: z.object({ at: isoInstant, id: z.string() }).optional(), placements: z.object({ at: isoInstant, id: z.string() }).optional() }).optional(), limit: z.number().int().min(1).max(200).default(100) },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, ({ since, cursor, limit }) => run(async () => {
    const fence = await syncCursor(db)
    const rows = await db.select({ ...getTableColumns(scheduleChanges), title: tasks.title }).from(scheduleChanges).leftJoin(tasks, eq(tasks.id, scheduleChanges.taskId)).where(and(
      gt(scheduleChanges.updatedAt, new Date(since)), lte(scheduleChanges.updatedAt, fence),
      cursor?.placements === undefined ? undefined : or(gt(scheduleChanges.updatedAt, new Date(cursor.placements.at)), and(eq(scheduleChanges.updatedAt, new Date(cursor.placements.at)), gt(scheduleChanges.id, cursor.placements.id))),
    )).orderBy(asc(scheduleChanges.updatedAt), asc(scheduleChanges.id)).limit(limit + 1)
    const taskRows = await db.select().from(tasks).where(and(gt(tasks.updatedAt, new Date(since)), lte(tasks.updatedAt, fence), cursor?.tasks === undefined ? undefined : or(gt(tasks.updatedAt, new Date(cursor.tasks.at)), and(eq(tasks.updatedAt, new Date(cursor.tasks.at)), gt(tasks.id, cursor.tasks.id))))).orderBy(tasks.updatedAt, tasks.id).limit(limit + 1)
    const projectRows = await db.select().from(projects).where(and(gt(projects.updatedAt, new Date(since)), lte(projects.updatedAt, fence), cursor?.projects === undefined ? undefined : or(gt(projects.updatedAt, new Date(cursor.projects.at)), and(eq(projects.updatedAt, new Date(cursor.projects.at)), gt(projects.id, cursor.projects.id))))).orderBy(projects.updatedAt, projects.id).limit(limit + 1)
    const changeType = (row: { createdAt: Date; deletedAt: Date | null; completedAt?: Date | null }) => row.deletedAt !== null ? 'deleted' : row.completedAt != null && row.completedAt > new Date(since) ? 'completed' : row.createdAt > new Date(since) ? 'created' : 'updated'
    const key = (row: { id: string; updatedAt: Date } | undefined) => row === undefined ? undefined : { at: row.updatedAt.toISOString(), id: row.id }
    const hasMore = [rows, taskRows, projectRows].some((items) => items.length > limit)
    return ok({
      tasks: taskRows.slice(0, limit).map((task) => ({ ...task, appUrl: `florida://tasks/${task.id}`, changeType: changeType(task) })),
      projects: projectRows.slice(0, limit).map((project) => ({ ...project, appUrl: `florida://projects/${project.id}`, changeType: changeType(project) })),
      placements: rows.slice(0, limit).map((row) => ({ id: row.id, taskId: row.taskId, title: row.title, appUrl: `florida://tasks/${row.taskId}`, changeType: row.changeType, previousPlacements: row.before, newPlacements: row.after, unscheduledReason: row.afterUnscheduled?.reason ?? null, previousUnscheduled: row.beforeUnscheduled, newUnscheduled: row.afterUnscheduled, reason: row.reason, changedAt: row.updatedAt })),
      hasMore, since: fence.toISOString(), nextCursor: hasMore ? { tasks: key(taskRows.slice(0, limit).at(-1)) ?? cursor?.tasks, projects: key(projectRows.slice(0, limit).at(-1)) ?? cursor?.projects, placements: key(rows.slice(0, limit).at(-1)) ?? cursor?.placements } : null,
    })
  }))

  server.registerTool('find_free_slots', {
    description: 'Returns maximal free windows within routine hours, at least durationMinutes long. Respects context, day overrides, blocking calendars, commitments, and (by default) all planned task/project time. Optional routine hours and hard-deadline overflow are excluded. Read-only; does not rerun the scheduler.',
    inputSchema: { windowStart: dueFilter, windowEnd: dueFilter, deadline: dueFilter.optional(), durationMinutes: z.number().int().min(1), context: taskContext.optional(), includeScheduledTasks: z.boolean().default(true), limit: z.number().int().min(1).max(100).default(20) },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, ({ windowStart, windowEnd, deadline, durationMinutes, context, includeScheduledTasks, limit }) => run(async () => {
    const timeZone = await defaultTimeZone(db)
    const instant = (value: string, inclusiveEnd: boolean) => {
      const date = parseCalendarDate(value)
      return date === undefined ? Date.parse(value) : zonedToUtc(inclusiveEnd ? dateFromDayNumber(dayNumber(date) + 1) : date, 0, timeZone)
    }
    const start = new Date(instant(windowStart, false)).toISOString()
    const end = new Date(Math.min(instant(windowEnd, true), deadline === undefined ? Infinity : instant(deadline, true))).toISOString()
    if (Date.parse(end) <= Date.parse(start) || Date.parse(end) - Date.parse(start) > 31 * 86400000) throw badRequest('Expected a positive range of at most 31 days after applying deadline')
    const blocks = await db.select().from(routineBlocks).where(isNull(routineBlocks.deletedAt))
    const overrides = await db.select().from(dayOverrides).where(isNull(dayOverrides.deletedAt))
    const eventRows = await db.select(getTableColumns(events)).from(events).innerJoin(calendars, eq(events.calendarId, calendars.id)).where(and(eq(calendars.blocksScheduling, true), isNull(events.deletedAt)))
    const planned = includeScheduledTasks ? [...await db.select().from(placements), ...await db.select().from(projectPlacements)] : []
    const [storedPlan] = await db.select().from(planSummary)
    const commitments = storedPlan === undefined ? undefined : await db.select().from(routineOccurrences)
    return ok({ timeZone, slots: findFreeSlots({
      start, end, durationMinutes, ...(context === undefined ? {} : { context }),
      routine: { timeZone, blocks: blocks.map((b) => ({ ...b, alternates: b.alternates ?? [] })) },
      dayOverrides: overrides.map((o) => ({ date: o.date, kind: o.kind })),
      busy: eventRows.flatMap((event) => { const interval = blockingEventInterval(event, timeZone); return interval === undefined ? [] : [interval] }),
      occupied: [
        ...planned.map((p) => ({ start: p.startAt.toISOString(), end: p.endAt.toISOString() })),
        ...(includeScheduledTasks ? (storedPlan?.catchUpBlocks ?? []).filter((p) => p.items.length > 0)
          .map((p) => ({ start: p.startAt, end: p.endAt })) : []),
      ],
      ...(commitments === undefined ? {} : { commitments: commitments.map((p) => ({ start: p.startAt.toISOString(), end: p.endAt.toISOString() })) }),
      ...(storedPlan === undefined ? {} : { commitmentWindow: { start: new Date(localWeeks(storedPlan.computedAt.getTime(), timeZone, 1)[0]!.start).toISOString(), end: new Date(storedPlan.computedAt.getTime() + (deps.horizonDays ?? 30) * 86400000).toISOString() } }),
    }).slice(0, limit).map((slot) => ({ startAt: slot.start, endAt: slot.end, durationMinutes: (Date.parse(slot.end) - Date.parse(slot.start)) / 60000 })) })
  }))

  server.registerTool('list_deleted_tasks', {
    title: 'List deleted tasks', description: 'Lists tombstoned tasks, most recently deleted first.',
    inputSchema: { query: z.string().optional(), limit: z.number().int().min(1).max(200).default(50) },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, ({ query, limit }) => run(async () => {
    const rows = await db.select().from(tasks).where(and(isNotNull(tasks.deletedAt), searchCondition(query))).orderBy(desc(tasks.deletedAt), asc(tasks.id)).limit(limit)
    return ok({ tasks: rows.map((task) => withPlacements(task, [])) })
  }))

  server.registerTool('restore_task', {
    title: 'Restore task', description: 'Restores one deleted task and reschedules. Does not restart a deleted recurring series or restore its other occurrences.',
    inputSchema: { id: taskId },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }, ({ id }) => run(async () => {
    const task = await db.transaction(async (tx) => {
      const [current] = await tx.select().from(tasks).where(eq(tasks.id, id))
      if (current === undefined) throw notFound(`task ${id}`)
      if (current.deletedAt === null) return current
      const [category] = await tx.select().from(categories).where(eq(categories.id, current.categoryId)).for('update')
      await tx.update(tasks).set({
        deletedAt: null, updatedAt: writeTimestamp,
        categoryId: category === undefined || category.deletedAt !== null ? INBOX_CATEGORY_ID : current.categoryId,
      }).where(and(eq(tasks.id, id), isNotNull(tasks.deletedAt)))
      return getTask(tx, id)
    })
    const scheduling = await reschedule('rescheduled due to task update')
    return ok({ task: withPlacements(task, await placementsFor([id])), scheduling: summary(scheduling) })
  }))

  server.registerTool('parse_task', {
    title: 'Parse task', description: 'Parses natural-language text into a draft without saving it. Requires AI configuration.',
    inputSchema: { text: z.string().trim().min(1).max(2000), now: isoInstant.optional(), timeZone: timeZone.optional() },
    annotations: { readOnlyHint: true, openWorldHint: true },
  }, ({ text, now, timeZone: zone }) => run(async () => {
    if (deps.ai === undefined) throw new HTTPException(503, { message: 'ai is not configured (set ANTHROPIC_API_KEY)' })
    const draft = await deps.ai.parse(text, {
      now: now === undefined ? new Date() : new Date(now),
      timeZone: zone ?? await defaultTimeZone(db),
      categories: await categoriesWithExamples(db),
      projects: await db.select({ id: projects.id, name: projects.name, parallel: projects.parallel }).from(projects)
        .where(and(isNull(projects.deletedAt), eq(projects.status, 'active'))).orderBy(projects.sortOrder, projects.name),
    })
    return ok({ draft })
  }))

  server.registerTool('list_calendars', {
    title: 'List calendars', description: 'Lists accounts and calendars without credentials; writableCalendarIds are selected owner/writer calendars.',
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, () => run(async () => {
    const accountRows = await db.select({ id: googleAccounts.id, email: googleAccounts.email, label: googleAccounts.label, displayName: googleAccounts.displayName, createdAt: googleAccounts.createdAt, updatedAt: googleAccounts.updatedAt }).from(googleAccounts)
    const calendarRows = await db.select({ id: calendars.id, accountId: calendars.accountId, googleId: calendars.googleId, summary: calendars.summary, color: calendars.color, accessRole: calendars.accessRole, selected: calendars.selected, blocksScheduling: calendars.blocksScheduling, lastSyncedAt: calendars.lastSyncedAt, channelExpiresAt: calendars.channelExpiresAt, updatedAt: calendars.updatedAt }).from(calendars)
    return ok({
      accounts: accountRows.map((account) => ({ ...account, calendars: calendarRows.filter((calendar) => calendar.accountId === account.id) })),
      calendars: calendarRows,
      writableCalendarIds: calendarRows.filter((calendar) => calendar.selected && ['owner', 'writer'].includes(calendar.accessRole)).map((calendar) => calendar.id),
    })
  }))

  server.registerTool('upsert_event', {
    title: 'Create or update event', description: 'Writes an event through to Google and reschedules. Omit id to generate a UUID; use the same id to retry creation. Attendees sends guest invitations; omit to keep guests, or pass [] to remove guests while preserving self and organizer.',
    inputSchema: { id: z.uuid().optional(), ...eventBody.shape },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true },
  }, ({ id, ...body }) => run(async () => {
    const [current] = id === undefined ? [] : await db.select({ id: events.id }).from(events).where(eq(events.id, id))
    const event = await upsertEvent(db, requireSync(), id ?? randomUUID(), eventBody.parse(body))
    const scheduling = await reschedule(current === undefined ? 'rescheduled due to new event' : 'rescheduled due to updated event')
    if (event.deletedAt !== null) throw notFound(`event ${event.id}`)
    return ok({ event, scheduling: summary(scheduling) })
  }))

  server.registerTool('delete_event', {
    title: 'Delete event', description: 'Deletes an event through Google, tombstones it, and reschedules.',
    inputSchema: { id: z.string().min(1) },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true },
  }, ({ id }) => run(async () => {
    await softDeleteEvent(db, requireSync(), id)
    return ok({ deleted: id, scheduling: summary(await reschedule('rescheduled due to deleted event')) })
  }))

  server.registerTool('set_event_blocks_day', {
    title: 'Set event day blocking', description: 'Overrides all-day blocking locally: true blocks, false frees, null restores automatic judgment.',
    inputSchema: { id: z.string().min(1), blocksDay: z.boolean().nullable() },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }, ({ id, blocksDay }) => run(async () => {
    const event = await setEventBlocksDay(db, id, blocksDay)
    return ok({ event, scheduling: summary(await reschedule('rescheduled due to event day-block change')) })
  }))

  server.registerTool('sync_google_calendar', {
    title: 'Sync Google Calendar', description: 'Awaits Google sync when configured, then reschedules.',
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true },
  }, () => run(async () => {
    await deps.sync?.syncAll()
    return ok({ scheduling: summary(await reschedule('rescheduled due to Google Calendar sync')) })
  }))

  function requireSync() {
    if (deps.sync === undefined) throw new HTTPException(503, { message: 'Google Calendar sync is not configured' })
    return deps.sync
  }

  server.registerTool(
    'list_categories',
    {
      title: 'List categories',
      description: 'Lists live categories with their area (work or personal; the inbox has none).',
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    () =>
      run(async () => {
        const rows = await db
          .select()
          .from(categories)
          .where(isNull(categories.deletedAt))
          .orderBy(...categoryListOrder)
        return ok({ categories: rows })
      }),
  )

  server.registerTool(
    'list_tasks',
    {
      title: 'List tasks',
      description:
        'Lists open tasks (soonest due first, undated last) with their scheduled blocks. Inbox includes unfiled tasks and categorized tasks with no due, start, pin, waiting or Someday decision; other category lists exclude those Inbox tasks. Someday and indefinite waiting tasks stay off the plan. Completed tasks are excluded unless includeCompleted is true.',
      inputSchema: {
        categoryId: z.string().min(1).optional().describe('Only tasks in this category view; inbox is the derived needs-triage list'),
        includeCompleted: z.boolean().default(false),
        query: z.string().optional(),
        dueBefore: dueFilter.optional(),
        dueAfter: dueFilter.optional(),
        context: taskContext.optional(),
        projectId: z.union([z.uuid(), z.literal('none')]).nullable().optional(),
        priority: priority.optional(),
        someday: z.boolean().optional(),
        tag: z.string().trim().toLowerCase().min(1).max(64).optional(),
        tags: taskTags.optional(),
        waiting: z.boolean().optional(),
        scheduledOn: calendarDate.optional(),
        hasSource: z.boolean().optional(),
        limit: z.number().int().min(1).max(200).default(50),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    ({ categoryId, includeCompleted, limit, ...filters }) =>
      run(async () => {
        const conditions = [isNull(tasks.deletedAt)]
        if (!includeCompleted) conditions.push(isNull(tasks.completedAt))
        const search = searchCondition(filters.query)
        if (search) conditions.push(search)
        if (filters.context !== undefined) conditions.push(eq(tasks.context, filters.context))
        if (filters.priority !== undefined) conditions.push(eq(tasks.priority, filters.priority))
        if (filters.someday !== undefined) conditions.push(eq(tasks.someday, filters.someday))
        if (filters.waiting !== undefined) conditions.push(filters.waiting ? isNotNull(tasks.waitingOn) : isNull(tasks.waitingOn))
        const tags = [...(filters.tags ?? []), ...(filters.tag === undefined ? [] : [filters.tag])]
        if (tags.length > 0) conditions.push(sql`${tasks.tags} @> ${JSON.stringify(tags)}::jsonb`)
        if (filters.projectId !== undefined) conditions.push(filters.projectId === null || filters.projectId === 'none' ? isNull(tasks.projectId) : eq(tasks.projectId, filters.projectId))
        if (filters.hasSource !== undefined) {
          const hasSource = sql`coalesce(${tasks.source}->>'url', '') <> ''`
          conditions.push(filters.hasSource ? hasSource : sql`not (${hasSource})`)
        }
        const tz = await defaultTimeZone(db)
        for (const [value, before] of [[filters.dueBefore, true], [filters.dueAfter, false]] as const) {
          if (value === undefined) continue
          const date = parseCalendarDate(value)
          const instant = date === undefined ? new Date(value) : new Date(zonedToUtc(before ? dateFromDayNumber(dayNumber(date) + 1) : date, 0, tz))
          conditions.push(before ? (date === undefined ? lte(tasks.dueAt, instant) : lt(tasks.dueAt, instant)) : gte(tasks.dueAt, instant))
        }
        if (filters.scheduledOn !== undefined) {
          const date = parseCalendarDate(filters.scheduledOn)!
          const start = new Date(zonedToUtc(date, 0, tz))
          const end = new Date(zonedToUtc(dateFromDayNumber(dayNumber(date) + 1), 0, tz))
          const scheduled = db.select({ id: placements.taskId }).from(placements).innerJoin(tasks, eq(placements.taskId, tasks.id)).where(and(taskPlacementVisible(placements.startAt, placements.pinned), lt(placements.startAt, end), gt(placements.endAt, start)))
          conditions.push(or(inArray(tasks.id, scheduled), and(gte(tasks.pinnedStart, start), lt(tasks.pinnedStart, end)))!)
        }
        if (categoryId === 'inbox') {
          conditions.push(or(eq(tasks.categoryId, 'inbox'), and(isNull(tasks.dueAt), isNull(tasks.startAt), isNull(tasks.pinnedStart), isNull(tasks.waitingOn), eq(tasks.someday, false)))!)
        } else if (categoryId !== undefined) {
          conditions.push(eq(tasks.categoryId, categoryId), or(isNotNull(tasks.dueAt), isNotNull(tasks.startAt), isNotNull(tasks.pinnedStart), isNotNull(tasks.waitingOn), eq(tasks.someday, true))!)
        }
        const rows = await db
          .select()
          .from(tasks)
          .where(and(...conditions))
          .orderBy(asc(tasks.dueAt), asc(tasks.createdAt))
          .limit(limit)
        const blocks = await placementsFor(rows.map((t) => t.id))
        return ok({ tasks: rows.map((t) => withPlacements(t, blocks)) })
      }),
  )

  server.registerTool(
    'get_task',
    {
      title: 'Get task',
      description: 'One task with its scheduled blocks.',
      inputSchema: { id: taskId },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    ({ id }) =>
      run(async () => {
        const task = await getTask(db, id)
        return ok({ task: withPlacements(task, await placementsFor([id])) })
      }),
  )

  server.registerTool(
    'create_task',
    {
      title: 'Create task',
      description:
        'Creates a one-off or recurring task and reschedules. Recurrence generates separate upcoming tasks, not just a new task after completion. Returns the task with its scheduled blocks plus scheduling issues.',
      inputSchema: {
        ...createTaskInput.shape,
        dryRun: dryRunInput,
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    ({ dryRun, ...args }) => run(() => write([{ tool: 'create_task', arguments: args }], dryRun, true)),
  )

  server.registerTool(
    'update_task',
    {
      title: 'Update task',
      description:
        'Changes the given fields and reschedules. Omitted fields keep their value; null clears. For recurring tasks, template/rule edits apply to this and future unfinished occurrences; recurrence: null stops future repeats and keeps this task.',
      inputSchema: { id: taskId, ...updateTaskInput.shape, dryRun: dryRunInput },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    ({ dryRun, ...args }) => run(() => write([{ tool: 'update_task', arguments: args }], dryRun, true)),
  )

  server.registerTool(
    'complete_task',
    {
      title: 'Complete task',
      description: 'Marks just this occurrence done now and reschedules the rest. Recurring tasks keep repeating.',
      inputSchema: { id: taskId },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    ({ id }) =>
      run(async () => {
        const task = await completeTask(db, id)
        const scheduling = await reschedule('rescheduled due to task update')
        return ok({ task: withPlacements(task, await placementsFor([id])), scheduling: summary(scheduling) })
      }),
  )

  server.registerTool(
    'delete_task',
    {
      title: 'Delete task',
      description: 'Deletes a task (tombstone) and reschedules. For a recurring task, also stops repeats and deletes future unfinished occurrences; other completed occurrences remain.',
      inputSchema: { id: taskId },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    },
    ({ id }) =>
      run(async () => {
        await softDeleteTask(db, id)
        const scheduling = await reschedule('rescheduled due to task update')
        return ok({ deleted: id, scheduling: summary(scheduling) })
      }),
  )

  server.registerTool(
    'list_projects',
    {
      title: 'List projects',
      description: 'Lists live projects with their status, next step, weekly budget and number of open tasks.',
      inputSchema: {
        status: z.enum(['thinking', 'active', 'on_hold', 'done']).optional().describe('Only projects with this status'),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    ({ status }) =>
      run(async () => {
        const conditions = [isNull(projects.deletedAt)]
        if (status !== undefined) conditions.push(eq(projects.status, status))
        const rows = await db
          .select()
          .from(projects)
          .where(and(...conditions))
          .orderBy(projects.sortOrder, projects.name)
        const open = await db
          .select({ projectId: tasks.projectId })
          .from(tasks)
          .where(and(isNull(tasks.deletedAt), isNull(tasks.completedAt)))
        return ok({
          projects: rows.map((p) => ({ ...p, appUrl: `florida://projects/${p.id}`, openTasks: open.filter((t) => t.projectId === p.id).length })),
        })
      }),
  )

  server.registerTool(
    'create_project',
    {
      title: 'Create project',
      description: 'Creates a project and reschedules. Add tasks to it by setting their projectId.',
      inputSchema: {
        ...projectBody.shape,
        id: z.string().min(1).optional().describe('Client-chosen id; a UUID is generated when omitted'),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    ({ id, ...body }) =>
      run(async () => {
        const project = await upsertProject(db, id ?? randomUUID(), body)
        const scheduling = await reschedule('rescheduled due to project update')
        return ok({ project: { ...project, appUrl: `florida://projects/${project.id}` }, scheduling: summary(scheduling) })
      }),
  )

  server.registerTool(
    'update_project',
    {
      title: 'Update project',
      description:
        'Changes the given fields and reschedules. Omitted fields keep their value; null clears. Setting status to on_hold, thinking or done takes the project’s tasks out of the plan; active puts them back.',
      inputSchema: { id: z.string().min(1).describe('Project id'), ...projectPatch.shape, dryRun: dryRunInput },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    ({ dryRun, ...args }) => run(() => write([{ tool: 'update_project', arguments: args }], dryRun, true)),
  )

  server.registerTool(
    'delete_project',
    {
      title: 'Delete project',
      description: 'Deletes a project (tombstone) and reschedules. Its tasks stay, without a project. To stop work without losing the project, set its status to on_hold or done instead.',
      inputSchema: { id: z.string().min(1).describe('Project id') },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    },
    ({ id }) =>
      run(async () => {
        await softDeleteProject(db, id)
        const scheduling = await reschedule('rescheduled due to project update')
        return ok({ deleted: id, scheduling: summary(scheduling) })
      }),
  )

  server.registerTool(
    'set_day',
    {
      title: 'Set day',
      description:
        'Marks one date as different from its weekday’s routine and reschedules: home (work from home), office (go in), or off (nothing planned, no gym). Replaces an earlier setting for that date.',
      inputSchema: { date: calendarDate.describe('YYYY-MM-DD in the routine’s time zone'), ...dayOverrideBody.shape, dryRun: dryRunInput },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    ({ dryRun, ...args }) => run(() => write([{ tool: 'set_day', arguments: args }], dryRun, true)),
  )

  server.registerTool(
    'clear_day',
    {
      title: 'Clear day',
      description: 'Puts a date back on its weekday’s routine and reschedules.',
      inputSchema: { date: calendarDate.describe('YYYY-MM-DD in the routine’s time zone') },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    ({ date }) =>
      run(async () => {
        await clearDayOverride(db, date)
        const scheduling = await reschedule('rescheduled due to day override')
        return ok({ cleared: date, scheduling: summary(scheduling) })
      }),
  )

  server.registerTool(
    'get_brief',
    {
      title: 'Get brief',
      description: 'The latest morning brief and weekly review, as written by the planner. Empty until the first one is written.',
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    () => run(async () => ok({ briefs: await latestBriefs(db) })),
  )

  server.registerTool(
    'get_agenda',
    {
      title: 'Get agenda',
      description:
        'One calendar day: events, planned task blocks, project time, commitments, any Catch up block with Later links, and the day’s override. Defaults to today in the home time zone.',
      inputSchema: {
        date: calendarDate.optional().describe('YYYY-MM-DD; defaults to today'),
        timeZone: timeZone.optional().describe('IANA zone the day is measured in; defaults to the routine’s zone'),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    (args) =>
      run(async () => {
        const { tz, catchUpBlocks } = await agendaContext(args.timeZone)
        const date = (args.date === undefined ? undefined : parseCalendarDate(args.date)) ?? localDate(Date.now(), tz)
        return ok((await agendaDays(date, date, tz, catchUpBlocks))[0]!)
      }),
  )

  server.registerTool('get_range', {
    title: 'Get agenda range',
    description: 'Inclusive range of up to 31 calendar days in the home time zone, with the same day shape as get_agenda.',
    inputSchema: { startDate: calendarDate, endDate: calendarDate },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, ({ startDate, endDate }) => run(async () => {
    const start = parseCalendarDate(startDate)!
    const end = parseCalendarDate(endDate)!
    const span = dayNumber(end) - dayNumber(start) + 1
    if (span < 1 || span > 31) throw badRequest('endDate must be on or after startDate; range must contain at most 31 days')
    const { tz, catchUpBlocks } = await agendaContext()
    return ok({ startDate, endDate, timeZone: tz, days: await agendaDays(start, end, tz, catchUpBlocks) })
  }))

  server.registerTool(
    'run_scheduler',
    {
      title: 'Run scheduler',
      description: 'Reruns the scheduler over all open tasks and returns every placement.',
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    () => run(async () => ok({ scheduling: await reschedule('manual scheduler run') })),
  )

  return server

  async function write(operations: WriteOperation[], dryRun: boolean, single = false): Promise<CallToolResult> {
    const rollback = new Error('preview rollback')
    let previous: PlacementRow[] = []
    let previousUnscheduled: SchedulerResult['unscheduled'] = []
    let previousLate = new Set<string>()
    const apply = async (store: Db): Promise<Record<string, unknown>[]> => {
      await store.execute(sql`select pg_advisory_xact_lock(731104)`)
      await lockTaskRecurrences(store)
      previous = await store.select().from(placements)
      previousUnscheduled = await store.select().from(unscheduled)
      const baselineTasks = await store.select().from(tasks).where(and(isNull(tasks.deletedAt), isNull(tasks.completedAt)))
      previousLate = new Set(baselineTasks.filter((task) => task.dueAt !== null && task.deadlineType !== 'none' && previous.some((p) => p.taskId === task.id && !p.pinned && p.endAt > task.dueAt!)).map((t) => t.id))
      const results: Record<string, unknown>[] = []
      for (const op of operations) {
        switch (op.tool) {
          case 'create_task': {
            const { id, deadlineType: deadline, ...body } = op.arguments
            results.push({ task: await upsertTask(store, id ?? randomUUID(), { ...body, waitingUntil: await followUpInstant(store, body.waitingUntil), deadlineType: deadline ?? (body.dueAt == null ? 'none' : 'soft') }) })
            break
          }
          case 'update_task': {
            const { id, ...patch } = op.arguments
            results.push({ task: await patchTask(store, id, { ...patch, waitingUntil: await followUpInstant(store, patch.waitingUntil) }) })
            break
          }
          case 'complete_task': results.push({ task: await completeTask(store, op.arguments.id) }); break
          case 'delete_task': await softDeleteTask(store, op.arguments.id); results.push({ deleted: op.arguments.id }); break
          case 'set_day': {
            const { date, ...body } = op.arguments
            results.push({ dayOverride: await setDayOverride(store, date, body) })
            break
          }
          case 'clear_day': await clearDayOverride(store, op.arguments.date); results.push({ cleared: op.arguments.date }); break
          case 'update_project': {
            const { id, ...patch } = op.arguments
            const project = await patchProject(store, id, patch)
            results.push({ project: { ...project, appUrl: `florida://projects/${id}` } })
            break
          }
          case 'create_project': {
            const { id, ...body } = op.arguments
            const project = await upsertProject(store, id ?? randomUUID(), body)
            results.push({ project: { ...project, appUrl: `florida://projects/${project.id}` } })
            break
          }
          case 'delete_project': await softDeleteProject(store, op.arguments.id); results.push({ deleted: op.arguments.id }); break
        }
      }
      return results
    }
    const response = (results: Record<string, unknown>[], scheduling: SchedulerResult) => {
      const enriched = results.map((result) => {
        if (result.task === undefined) return result
        const task = result.task as TaskRow
        return { ...result, task: {
          ...task, appUrl: `florida://tasks/${task.id}`,
          placements: scheduling.placements.filter((p) => p.taskId === task.id).map((p) => ({ startAt: p.start, endAt: p.end, pinned: p.pinned })),
        } }
      })
      return ok({ ...(single ? enriched[0] : { results: enriched }), dryRun, scheduling: dryRun ? scheduling : summary(scheduling),
        newlyLate: scheduling.late.filter((item) => !previousLate.has(item.taskId)),
        newlyUnscheduled: scheduling.unscheduled.filter((item) => !previousUnscheduled.some((old) => old.taskId === item.taskId)),
        changes: placementChanges(previous, scheduling.placements, { now: new Date(), previousUnscheduled, unscheduled: scheduling.unscheduled }),
      })
    }
    let result: CallToolResult | undefined
    try {
      await db.transaction(async (tx) => {
        const results = await apply(tx)
        result = response(results, await runScheduling(tx, { HORIZON_DAYS: deps.horizonDays ?? 30 }, new Date(), single ? writeReason(operations[0]!.tool) : 'rescheduled due to batch update'))
        if (dryRun) throw rollback
      })
    } catch (error) {
      if (error !== rollback) throw error
    }
    if (!dryRun) deps.publish?.()
    return result!
  }

  async function agendaContext(timeZone?: string) {
    const [row] = await db.select({ timeZone: settings.timeZone, catchUpBlocks: planSummary.catchUpBlocks })
      .from(settings).fullJoin(planSummary, eq(settings.id, planSummary.id)).limit(1)
    return { tz: timeZone ?? row?.timeZone ?? 'UTC', catchUpBlocks: row?.catchUpBlocks?.filter((block) => block.items.length > 0) ?? [] }
  }

  async function agendaDays(date: LocalDate, last: LocalDate, tz: string, catchUpBlocks: CatchUpBlock[]) {
    const next = dateFromDayNumber(dayNumber(last) + 1)
    // Timed rows are compared against the zoned day; all-day rows are stored at UTC midnight of
    // their calendar date, so they are compared against the UTC day instead.
    const start = new Date(zonedToUtc(date, 0, tz))
    const end = new Date(zonedToUtc(next, 0, tz))
    const utcStart = new Date(utcMidnight(date))
    const utcEnd = new Date(utcMidnight(next))

    const eventRows = await db
      .select({
        id: events.id,
        calendarId: events.calendarId,
        calendar: calendars.summary,
        summary: events.summary,
        location: events.location,
        startAt: events.startAt,
        endAt: events.endAt,
        allDay: events.allDay,
        transparency: events.transparency,
        responseStatus: events.responseStatus,
        htmlLink: events.htmlLink,
        description: events.description,
        conferenceUrl: events.conferenceUrl,
        attendees: events.attendees,
      })
      .from(events)
      .innerJoin(calendars, eq(events.calendarId, calendars.id))
      .where(
        and(
          eq(calendars.selected, true),
          isNull(events.deletedAt),
          or(
            and(eq(events.allDay, false), lt(events.startAt, end), gt(events.endAt, start)),
            and(eq(events.allDay, true), lt(events.startAt, utcEnd), gt(events.endAt, utcStart)),
          ),
        ),
      )
      .orderBy(desc(events.allDay), asc(events.startAt))

    const blockRows = await db
      .select({
        taskId: placements.taskId,
        title: tasks.title,
        categoryId: tasks.categoryId,
        priority: tasks.priority,
        projectId: tasks.projectId,
        startAt: placements.startAt,
        endAt: placements.endAt,
        pinned: placements.pinned,
        lane: placements.lane,
      })
      .from(placements)
      .innerJoin(tasks, eq(placements.taskId, tasks.id))
      .where(and(taskPlacementVisible(placements.startAt, placements.pinned), lt(placements.startAt, end), gt(placements.endAt, start)))
      .orderBy(asc(placements.startAt))

    const projectTime = await db
      .select({
        projectId: projectPlacements.projectId,
        project: projects.name,
        startAt: projectPlacements.startAt,
        endAt: projectPlacements.endAt,
        lane: projectPlacements.lane,
      })
      .from(projectPlacements)
      .innerJoin(projects, eq(projectPlacements.projectId, projects.id))
      .where(and(lt(projectPlacements.startAt, end), gt(projectPlacements.endAt, start)))
      .orderBy(asc(projectPlacements.startAt))

    const commitments = await db
      .select({ name: routineBlocks.name, startAt: routineOccurrences.startAt, endAt: routineOccurrences.endAt })
      .from(routineOccurrences)
      .innerJoin(routineBlocks, eq(routineOccurrences.blockId, routineBlocks.id))
      .where(and(lt(routineOccurrences.startAt, end), gt(routineOccurrences.endAt, start)))
      .orderBy(asc(routineOccurrences.startAt))

    const overrides = await db
      .select({ date: dayOverrides.date, kind: dayOverrides.kind, note: dayOverrides.note })
      .from(dayOverrides)
      .where(and(gte(dayOverrides.date, formatCalendarDate(date)), lte(dayOverrides.date, formatCalendarDate(last)), isNull(dayOverrides.deletedAt)))

    return Array.from({ length: dayNumber(last) - dayNumber(date) + 1 }, (_, i) => {
      const day = dateFromDayNumber(dayNumber(date) + i)
      const following = dateFromDayNumber(dayNumber(day) + 1)
      const start = new Date(zonedToUtc(day, 0, tz))
      const end = new Date(zonedToUtc(following, 0, tz))
      const overlaps = (row: { startAt: Date | null, endAt: Date | null }, from = start.getTime(), to = end.getTime()) => row.startAt !== null && row.endAt !== null && row.startAt.getTime() < to && row.endAt.getTime() > from
      const override = overrides.find((row) => row.date === formatCalendarDate(day))
      return {
        date: formatCalendarDate(day), timeZone: tz, start, end,
        events: eventRows.filter((row) => row.allDay ? overlaps(row, utcMidnight(day), utcMidnight(following)) : overlaps(row)),
        taskBlocks: blockRows.filter((row) => overlaps(row)).map((row) => ({ ...row, appUrl: `florida://tasks/${row.taskId}` })),
        projectTime: projectTime.filter((row) => overlaps(row)),
        commitments: commitments.filter((row) => overlaps(row)),
        catchUpBlocks: catchUpBlocks.filter((block) => Date.parse(block.startAt) < end.getTime() && Date.parse(block.endAt) > start.getTime()),
        dayOverride: override === undefined ? null : { kind: override.kind, note: override.note },
      }
    })
  }

  async function placementsFor(ids: string[]): Promise<PlacementRow[]> {
    if (ids.length === 0) return []
    return db.select(getTableColumns(placements)).from(placements)
      .innerJoin(tasks, eq(placements.taskId, tasks.id))
      .where(and(taskPlacementVisible(placements.startAt, placements.pinned), inArray(placements.taskId, ids)))
      .orderBy(asc(placements.startAt))
  }
}

/**
 * Mounts a stateless Streamable HTTP MCP endpoint at `/mcp`. Callers add authentication before
 * calling this. Each POST gets its own transport and server (the SDK forbids reuse without
 * sessions); JSON response mode means the reply is complete when `handleRequest` resolves, so
 * closing in `finally` is safe. GET/DELETE answer 405: there is no session to stream to or end.
 */
export function mountMcp(app: Hono, deps: McpDeps): void {
  app.post('/mcp', async (c) => {
    const transport = new WebStandardStreamableHTTPServerTransport({ enableJsonResponse: true })
    const server = buildMcpServer(deps)
    await server.connect(transport)
    try {
      return await transport.handleRequest(c.req.raw)
    } finally {
      await server.close()
    }
  })
  app.on(['GET', 'DELETE'], '/mcp', (c) =>
    c.json({ jsonrpc: '2.0', error: { code: -32000, message: 'Method not allowed.' }, id: null }, 405),
  )
}

function withPlacements(task: TaskRow, all: PlacementRow[]) {
  return {
    ...task,
    appUrl: `florida://tasks/${task.id}`,
    placements: all
      .filter((p) => !task.someday && p.taskId === task.id)
      .map((p) => ({ startAt: p.startAt, endAt: p.endAt, pinned: p.pinned })),
  }
}

/** The parts of a scheduler result an agent acting on one task needs; the full placement list is `run_scheduler`'s job. */
function summary(result: SchedulerResult): Pick<SchedulerResult, 'unscheduled' | 'late'> {
  return { unscheduled: result.unscheduled, late: result.late }
}

function utcMidnight(date: LocalDate): number {
  return Date.UTC(date.year, date.month - 1, date.day)
}

async function followUpInstant(db: Db, value: string | null | undefined): Promise<string | null | undefined> {
  if (value == null) return value
  const date = parseCalendarDate(value)
  return date === undefined ? value : new Date(zonedToUtc(date, 0, await defaultTimeZone(db))).toISOString()
}

function ok(data: Record<string, unknown>): CallToolResult {
  return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }], structuredContent: data }
}

/** Turns the store's HTTP errors (400 unknown reference, 404) into tool errors the model can read and act on. */
async function run(fn: () => Promise<CallToolResult>): Promise<CallToolResult> {
  try {
    return await fn()
  } catch (err) {
    if (err instanceof HTTPException) return { content: [{ type: 'text', text: err.message }], isError: true }
    if (err instanceof z.ZodError || err instanceof GoogleApiError) return { content: [{ type: 'text', text: err.message }], isError: true }
    throw err
  }
}
