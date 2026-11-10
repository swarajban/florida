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
import { latestBriefs } from './briefs.js'
import { defaultTimeZone } from './db/queries.js'
import {
  calendars,
  categories,
  dayOverrides,
  events,
  placements,
  projectPlacements,
  projects,
  routineBlocks,
  routineOccurrences,
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
  'Florida is a single-user task planner and calendar. Tasks belong to categories (each in the work or',
  'personal area) and carry a context: computer (anywhere with a laptop), errand (out and about), home',
  '(only at home) or office (only at the office). A weekly routine says which contexts fit which hours;',
  'after each change the scheduler places open tasks into routine blocks that allow their context,',
  'around calendar events, and returns placements: suggested work blocks, not calendar events. Call',
  'list_categories first to learn the category ids, get_agenda to see one day of calendar events plus',
  'planned task blocks, and list_tasks for what is open. Instants are ISO 8601 strings.',
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
      description: 'Lists live categories with their area (work or personal; the inbox has none).',
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
        'Creates a one-off or recurring task and reschedules. Recurrence generates separate upcoming tasks, not just a new task after completion. Returns the task with its scheduled blocks plus scheduling issues.',
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
        'Changes the given fields and reschedules. Omitted fields keep their value; null clears. For recurring tasks, template/rule edits apply to this and future unfinished occurrences; recurrence: null stops future repeats and keeps this task.',
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
      description: 'Marks just this occurrence done now and reschedules the rest. Recurring tasks keep repeating.',
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
      description: 'Deletes a task (tombstone) and reschedules. For a recurring task, also stops repeats and deletes future unfinished occurrences; other completed occurrences remain.',
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
          projects: rows.map((p) => ({ ...p, openTasks: open.filter((t) => t.projectId === p.id).length })),
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
        const scheduling = await reschedule()
        return ok({ project, scheduling: summary(scheduling) })
      }),
  )

  server.registerTool(
    'update_project',
    {
      title: 'Update project',
      description:
        'Changes the given fields and reschedules. Omitted fields keep their value; null clears. Setting status to on_hold, thinking or done takes the project’s tasks out of the plan; active puts them back.',
      inputSchema: { id: z.string().min(1).describe('Project id'), ...projectPatch.shape },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    ({ id, ...patch }) =>
      run(async () => {
        const project = await patchProject(db, id, patch)
        const scheduling = await reschedule()
        return ok({ project, scheduling: summary(scheduling) })
      }),
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
        const scheduling = await reschedule()
        return ok({ deleted: id, scheduling: summary(scheduling) })
      }),
  )

  server.registerTool(
    'set_day',
    {
      title: 'Set day',
      description:
        'Marks one date as different from its weekday’s routine and reschedules: home (work from home), office (go in), or off (nothing planned, no gym). Replaces an earlier setting for that date.',
      inputSchema: { date: calendarDate.describe('YYYY-MM-DD in the routine’s time zone'), ...dayOverrideBody.shape },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    ({ date, ...body }) =>
      run(async () => {
        const dayOverride = await setDayOverride(db, date, body)
        const scheduling = await reschedule()
        return ok({ dayOverride, scheduling: summary(scheduling) })
      }),
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
        const scheduling = await reschedule()
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
        'One calendar day: calendar events (from selected calendars, all-day first), planned task blocks (those with a lane run side by side), project time, commitments such as the gym, and the day’s override if it has one. Defaults to today in the home time zone.',
      inputSchema: {
        date: calendarDate.optional().describe('YYYY-MM-DD; defaults to today'),
        timeZone: timeZone.optional().describe('IANA zone the day is measured in; defaults to the routine’s zone'),
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
          .where(and(lt(placements.startAt, end), gt(placements.endAt, start)))
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

        const [override] = await db
          .select({ kind: dayOverrides.kind, note: dayOverrides.note })
          .from(dayOverrides)
          .where(and(eq(dayOverrides.date, formatCalendarDate(date)), isNull(dayOverrides.deletedAt)))

        return ok({
          date: formatCalendarDate(date),
          timeZone: tz,
          start,
          end,
          events: eventRows,
          taskBlocks: blockRows,
          projectTime,
          commitments,
          dayOverride: override ?? null,
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
