import { randomUUID } from 'node:crypto'
import { dateFromDayNumber, dayNumber, localDate, zonedToUtc } from '@florida/scheduler'
import type { LocalDate, SchedulerResult } from '@florida/scheduler'
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js'
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js'
import { and, asc, desc, eq, gt, inArray, isNull, lt, or } from 'drizzle-orm'
import type { Hono } from 'hono'
import { HTTPException } from 'hono/http-exception'
import { z } from 'zod'
import type { Db } from './db/client.js'
import { defaultTimeZone } from './db/queries.js'
import { calendars, events, placements, categories, tasks } from './db/schema.js'
import type { PlacementRow, TaskRow } from './db/schema.js'
import {
  completeTask,
  deadlineType,
  getTask,
  patchTask,
  priority,
  softDeleteTask,
  taskBody,
  taskPatch,
  upsertTask,
} from './tasks.js'
import { calendarDate, formatCalendarDate, parseCalendarDate, timeZone } from './validation.js'

export interface McpDeps {
  db: Db
  /** Reruns the scheduler and notifies connected clients; the app's wrapper around `runScheduling`. */
  reschedule: () => Promise<SchedulerResult>
}

const SERVER_INFO = { name: 'florida', version: '0.1.0' }

const INSTRUCTIONS = [
  'Florida is a single-user task planner and calendar. Tasks belong to categories; every category has a',
  'schedule (working hours in an IANA time zone). After each change the scheduler places open tasks',
  'into free time around calendar events and returns placements: suggested work blocks, not calendar',
  'events. Call list_categories first to learn the category ids, get_agenda to see one day of calendar',
  'events plus planned task blocks, and list_tasks for what is open. Instants are ISO 8601 strings.',
].join(' ')

const taskId = z.string().min(1).describe('Task id')

/**
 * Builds a fresh MCP server over the task store. Stateless transports need a new `McpServer` per
 * request, so this is called from `mountMcp` on every POST rather than once at startup.
 */
export function buildMcpServer(deps: McpDeps): McpServer {
  const { db, reschedule } = deps
  const server = new McpServer(SERVER_INFO, { instructions: INSTRUCTIONS })

  server.registerTool(
    'list_categories',
    {
      title: 'List categories',
      description: 'Lists live categories with the schedule each one uses.',
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    () =>
      run(async () => {
        const rows = await db
          .select()
          .from(categories)
          .where(isNull(categories.deletedAt))
          .orderBy(categories.sortOrder, categories.name)
        return ok({ categories: rows })
      }),
  )

  server.registerTool(
    'list_tasks',
    {
      title: 'List tasks',
      description:
        'Lists open tasks (soonest due first, undated last) with their scheduled blocks. Completed tasks are excluded unless includeCompleted is true.',
      inputSchema: {
        categoryId: z.string().min(1).optional().describe('Only tasks in this category'),
        includeCompleted: z.boolean().default(false),
        limit: z.number().int().min(1).max(200).default(50),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    ({ categoryId, includeCompleted, limit }) =>
      run(async () => {
        const conditions = [isNull(tasks.deletedAt)]
        if (!includeCompleted) conditions.push(isNull(tasks.completedAt))
        if (categoryId !== undefined) conditions.push(eq(tasks.categoryId, categoryId))
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
        'Creates a task and reschedules. Returns the task with its scheduled blocks plus any tasks the scheduler could not place or expects to be late.',
      inputSchema: {
        ...taskBody.shape,
        id: z.string().min(1).optional().describe('Client-chosen id; a UUID is generated when omitted'),
        durationMinutes: z.number().int().min(1).default(30),
        priority: priority.default('medium'),
        deadlineType: deadlineType.optional().describe("Defaults to 'soft' when dueAt is set, otherwise 'none'"),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    ({ id, deadlineType: deadline, ...rest }) =>
      run(async () => {
        const newId = id ?? randomUUID()
        const task = await upsertTask(db, newId, {
          ...rest,
          deadlineType: deadline ?? (rest.dueAt == null ? 'none' : 'soft'),
        })
        const scheduling = await reschedule()
        return ok({ task: withPlacements(task, await placementsFor([newId])), scheduling: summary(scheduling) })
      }),
  )

  server.registerTool(
    'update_task',
    {
      title: 'Update task',
      description:
        'Changes the given fields of a task and reschedules. Omitted fields keep their value; pass null to clear a nullable field.',
      inputSchema: { id: taskId, ...taskPatch.shape },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    ({ id, ...patch }) =>
      run(async () => {
        const task = await patchTask(db, id, patch)
        const scheduling = await reschedule()
        return ok({ task: withPlacements(task, await placementsFor([id])), scheduling: summary(scheduling) })
      }),
  )

  server.registerTool(
    'complete_task',
    {
      title: 'Complete task',
      description: 'Marks a task done now and reschedules the rest.',
      inputSchema: { id: taskId },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    ({ id }) =>
      run(async () => {
        const task = await completeTask(db, id)
        const scheduling = await reschedule()
        return ok({ task, scheduling: summary(scheduling) })
      }),
  )

  server.registerTool(
    'delete_task',
    {
      title: 'Delete task',
      description: 'Deletes a task (recoverable tombstone) and reschedules the rest.',
      inputSchema: { id: taskId },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    },
    ({ id }) =>
      run(async () => {
        await softDeleteTask(db, id)
        const scheduling = await reschedule()
        return ok({ deleted: id, scheduling: summary(scheduling) })
      }),
  )

  server.registerTool(
    'get_agenda',
    {
      title: 'Get agenda',
      description:
        'Calendar events (from selected calendars) and planned task blocks for one calendar day, all-day events first. Defaults to today in the home time zone.',
      inputSchema: {
        date: calendarDate.optional().describe('YYYY-MM-DD; defaults to today'),
        timeZone: timeZone.optional().describe('IANA zone the day is measured in; defaults to the first schedule’s zone'),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    (args) =>
      run(async () => {
        const tz = args.timeZone ?? (await defaultTimeZone(db))
        const date = (args.date === undefined ? undefined : parseCalendarDate(args.date)) ?? localDate(Date.now(), tz)
        const next = dateFromDayNumber(dayNumber(date) + 1)
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
            startAt: placements.startAt,
            endAt: placements.endAt,
            pinned: placements.pinned,
          })
          .from(placements)
          .innerJoin(tasks, eq(placements.taskId, tasks.id))
          .where(and(lt(placements.startAt, end), gt(placements.endAt, start)))
          .orderBy(asc(placements.startAt))

        return ok({
          date: formatCalendarDate(date),
          timeZone: tz,
          start,
          end,
          events: eventRows,
          taskBlocks: blockRows,
        })
      }),
  )

  server.registerTool(
    'run_scheduler',
    {
      title: 'Run scheduler',
      description: 'Reruns the scheduler over all open tasks and returns every placement.',
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    () => run(async () => ok({ scheduling: await reschedule() })),
  )

  return server

  async function placementsFor(ids: string[]): Promise<PlacementRow[]> {
    if (ids.length === 0) return []
    return db.select().from(placements).where(inArray(placements.taskId, ids)).orderBy(asc(placements.startAt))
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
    placements: all
      .filter((p) => p.taskId === task.id)
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

function ok(data: Record<string, unknown>): CallToolResult {
  return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }], structuredContent: data }
}

/** Turns the store's HTTP errors (400 unknown reference, 404) into tool errors the model can read and act on. */
async function run(fn: () => Promise<CallToolResult>): Promise<CallToolResult> {
  try {
    return await fn()
  } catch (err) {
    if (err instanceof HTTPException) return { content: [{ type: 'text', text: err.message }], isError: true }
    throw err
  }
}
