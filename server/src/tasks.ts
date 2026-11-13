import { randomUUID } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'
import { and, eq, gt, gte, isNull, ne, sql } from 'drizzle-orm'
import { writeTimestamp } from './db/sync-clock.js'
import { HTTPException } from 'hono/http-exception'
import { z } from 'zod'
import type { Db } from './db/client.js'
import { categoryExists, projectExists, scheduleExists } from './db/queries.js'
import { taskRecurrences, tasks } from './db/schema.js'
import type { TaskRow } from './db/schema.js'
import { addCalendarDays, localDay, nextOccurrence, occurrenceDates, occurrenceFields, recurrenceRule } from './recurrence.js'
import type { RecurringTaskTemplate } from './recurrence.js'
import { normalizeTaskSource, taskSourceInput } from './task-source.js'
import { badRequest, isoInstant, notFound, toDate } from './validation.js'

export const priority = z.enum(['asap', 'high', 'medium', 'low'])
export const deadlineType = z.enum(['hard', 'soft', 'none'])
export const taskContext = z.enum(['computer', 'errand', 'home', 'office'])
export const attention = z.enum(['full', 'shared'])

/** Full task body as accepted by `PUT /api/tasks/:id` and the MCP tools. */
export const taskBody = z.object({
  categoryId: z.string().min(1),
  title: z.string().min(1),
  notes: z.string().nullish(),
  source: taskSourceInput.nullish(),
  durationMinutes: z.number().int().min(1),
  minChunkMinutes: z.number().int().min(1).nullish(),
  priority,
  deadlineType,
  dueAt: isoInstant.nullish(),
  someday: z.boolean().optional().describe('Keeps a task off the plan, with no due date or pin. Explicit true clears dueAt and pinnedStart but keeps startAt. When omitted, setting a changed nonnull due/start/pin turns it off; unrelated edits and same-value retries preserve it. A same-date scheduling action must send false. Defaults to false on creation.'),
  startAt: isoInstant.nullish(),
  scheduleId: z.string().min(1).nullish(),
  context: taskContext
    .optional()
    .describe(
      'Where the task can be done: computer (anywhere with a laptop), errand (out, e.g. a store), home (only at home), office (only at the office). Defaults to computer; omitting it on an edit keeps the stored value.',
    ),
  projectId: z
    .string()
    .min(1)
    .nullish()
    .describe('The project this task belongs to, or null for none. Tasks of a project that is not active are not scheduled. Omitting it on an edit keeps the stored value.'),
  attention: attention
    .nullish()
    .describe(
      'full: needs the user alone. shared: mostly runs itself (an agent does the work) and may be planned beside up to two other shared tasks of other projects. null follows the project (shared when it is parallel). Omitting it on an edit keeps the stored value.',
    ),
  pinnedStart: isoInstant.nullish(),
  recurrence: recurrenceRule.nullish(),
  expectedRecurrenceRevision: z.string().min(1).nullish(),
  completedMinutes: z.number().int().min(0).nullish(),
  completedAt: isoInstant.nullish(),
})
export type TaskBody = z.infer<typeof taskBody>

/** Partial task body: absent fields keep their stored value, `null` clears a nullable field. */
export const taskPatch = taskBody.partial()
export type TaskPatch = z.infer<typeof taskPatch>

/** Creates or replaces a task. Undeletes a tombstoned id. Throws 400 for unknown references. */
export async function upsertTask(db: Db, id: string, body: TaskBody, now: Date = new Date()): Promise<TaskRow> {
  return db.transaction(async (tx) => {
    await lockTaskRecurrences(tx)
    return writeTask(tx, id, body, now)
  })
}

/** Serializes series edits, deletes, and expansion, including across server processes. */
export async function lockTaskRecurrences(db: Db): Promise<void> {
  await db.execute(sql`select pg_advisory_xact_lock(731105)`)
}

function taskFields(body: TaskBody, now: Date, current: TaskRow | undefined) {
  const dueAt = toDate(body.dueAt)
  const startAt = toDate(body.startAt)
  const pinnedStart = toDate(body.pinnedStart)
  const datesChanged = current !== undefined && (
    (dueAt !== null && dueAt.getTime() !== current.dueAt?.getTime())
    || (startAt !== null && startAt.getTime() !== current.startAt?.getTime())
    || (pinnedStart !== null && pinnedStart.getTime() !== current.pinnedStart?.getTime())
  )
  const someday = body.someday === true
    ? true
    : datesChanged ? false : body.someday ?? current?.someday ?? false
  return {
    categoryId: body.categoryId,
    title: body.title,
    notes: body.notes ?? null,
    source: body.source === undefined ? (current?.source ?? null) : body.source === null ? null : normalizeTaskSource(body.source),
    durationMinutes: body.durationMinutes,
    minChunkMinutes: body.minChunkMinutes ?? null,
    priority: body.priority,
    deadlineType: someday ? 'none' as const : body.deadlineType,
    dueAt: someday ? null : dueAt,
    someday,
    startAt,
    scheduleId: body.scheduleId ?? null,
    // Older shipped clients omit context; their edits must not reset a task to the default.
    context: body.context ?? current?.context ?? 'computer',
    // Likewise: absent keeps, null clears.
    projectId: body.projectId === undefined ? (current?.projectId ?? null) : body.projectId,
    attention: body.attention === undefined ? (current?.attention ?? null) : body.attention,
    pinnedStart: someday ? null : pinnedStart,
    completedMinutes: body.completedMinutes ?? 0,
    completedAt: toDate(body.completedAt),
    updatedAt: now,
    deletedAt: null,
  }
}

function seriesTemplate(fields: Pick<TaskRow, keyof ReturnType<typeof taskFields>>, anchorDate: string): RecurringTaskTemplate {
  return {
    anchorDate,
    categoryId: fields.categoryId,
    title: fields.title,
    notes: fields.notes,
    source: fields.source,
    durationMinutes: fields.durationMinutes,
    minChunkMinutes: fields.minChunkMinutes,
    priority: fields.priority,
    deadlineType: fields.deadlineType,
    dueAt: fields.dueAt?.toISOString() ?? null,
    someday: fields.someday,
    startAt: fields.startAt?.toISOString() ?? null,
    scheduleId: fields.scheduleId,
    context: fields.context,
    projectId: fields.projectId,
    attention: fields.attention,
    pinnedStart: fields.pinnedStart?.toISOString() ?? null,
  }
}

function checkRecurrenceRevision(current: TaskRow | undefined, body: TaskBody): void {
  if (current?.recurrenceRevision != null && body.expectedRecurrenceRevision !== current.recurrenceRevision) {
    throw new HTTPException(409, { message: 'recurring task changed elsewhere; refresh before editing its series' })
  }
}

async function writeTask(db: Db, id: string, body: TaskBody, now: Date): Promise<TaskRow> {
  if (!(await categoryExists(db, body.categoryId))) throw badRequest(`unknown categoryId ${body.categoryId}`)
  if (body.scheduleId != null && !(await scheduleExists(db, body.scheduleId))) {
    throw badRequest(`unknown scheduleId ${body.scheduleId}`)
  }
  if (body.projectId != null && !(await projectExists(db, body.projectId))) throw badRequest(`unknown projectId ${body.projectId}`)
  const [current] = await db.select().from(tasks).where(eq(tasks.id, id))
  // Older shipped clients omit recurrence; ordinary edits/completions must not switch repeats off.
  let recurrence = body.recurrence === undefined ? current?.recurrence ?? null : body.recurrence
  let recurrenceSeriesId = current?.recurrenceSeriesId ?? null
  let recurrenceDate = current?.recurrenceDate ?? null
  let recurrenceRevision = current?.recurrenceRevision ?? null
  let fields = taskFields(body, now, current)
  const [series] = recurrenceSeriesId === null ? [] : await db.select().from(taskRecurrences).where(eq(taskRecurrences.id, recurrenceSeriesId))

  if (series?.deletedAt != null) {
    // Stale queued writes may complete an old occurrence, but cannot restart a stopped series.
    if (recurrence !== null) checkRecurrenceRevision(current, body)
    recurrenceSeriesId = null
    recurrenceDate = null
    recurrence = null
    // This conversion must consume the old snapshot's revision, or an identical PUT retry
    // would now look like deliberate enabling on a detached one-off.
    recurrenceRevision = randomUUID()
  }
  if (recurrence === null && series?.deletedAt === null && current !== undefined) {
    checkRecurrenceRevision(current, body)
    recurrenceRevision = await stopRecurrence(db, current, now) ?? recurrenceRevision
    recurrenceSeriesId = null
    recurrenceDate = null
  } else if (recurrence !== null) {
    if (recurrenceSeriesId === null) {
      checkRecurrenceRevision(current, body)
      const first = nextOccurrence(recurrence, localDay(now, recurrence.timeZone))
      if (first === undefined) throw badRequest('recurrence has no upcoming occurrences')
      recurrenceSeriesId = randomUUID()
      recurrenceDate = first
      recurrenceRevision = randomUUID()
      const template = seriesTemplate(fields, recurrence.startDate)
      if (!template.someday && template.deadlineType === 'none') template.deadlineType = 'soft'
      await db.insert(taskRecurrences).values({ id: recurrenceSeriesId, revision: recurrenceRevision, rule: recurrence, template, fromDate: first, updatedAt: writeTimestamp })
      fields = { ...fields, ...occurrenceFields(template, recurrence, first) }
    } else if (current !== undefined && recurrenceDate !== null && series !== undefined) {
      if (!fields.someday && fields.deadlineType === 'none') fields.deadlineType = 'soft'
      // A retried creation still contains dates relative to the original rule anchor. Normalize
      // that request exactly as the first write; omitted dates otherwise mean local day bounds.
      const incoming = seriesTemplate(fields, series.template.anchorDate)
      const stored = { ...series.template, source: series.template.source ?? null }
      const source = isDeepStrictEqual(incoming, stored) && isDeepStrictEqual(recurrence, series.rule)
        ? stored
        : seriesTemplate(fields, recurrenceDate)
      fields = { ...fields, ...occurrenceFields(source, recurrence, recurrenceDate) }
      const template = seriesTemplate(fields, recurrenceDate)
      const previous = seriesTemplate(current, recurrenceDate)
      if (!isDeepStrictEqual(template, previous) || !isDeepStrictEqual(recurrence, current.recurrence)) {
        checkRecurrenceRevision(current, body)
        recurrenceRevision = randomUUID()
        // Replacing an earlier segment must also regenerate its intervening future dates.
        // Materialization separately clamps this boundary to today, so history is not backfilled.
        await db.update(taskRecurrences).set({ rule: recurrence, template, fromDate: recurrenceDate, revision: recurrenceRevision, updatedAt: writeTimestamp }).where(eq(taskRecurrences.id, recurrenceSeriesId))
        const future = await db.select().from(tasks).where(and(
          eq(tasks.recurrenceSeriesId, recurrenceSeriesId), gt(tasks.recurrenceDate, recurrenceDate),
          isNull(tasks.completedAt), isNull(tasks.deletedAt),
        ))
        for (const occurrence of future) {
          const date = occurrence.recurrenceDate
          if (date === null) continue
          if (nextOccurrence(recurrence, date) !== date) {
            await db.update(tasks).set({ deletedAt: now, updatedAt: writeTimestamp, recurrenceRevision }).where(eq(tasks.id, occurrence.id))
          } else {
            await db.update(tasks).set({ ...occurrenceFields(template, recurrence, date), recurrence, recurrenceRevision, updatedAt: writeTimestamp }).where(eq(tasks.id, occurrence.id))
          }
        }
      }
    }
  }
  const [task] = await db
    .insert(tasks)
    .values({ id, ...fields, recurrence, recurrenceSeriesId, recurrenceDate, recurrenceRevision, updatedAt: writeTimestamp })
    .onConflictDoUpdate({ target: tasks.id, set: { ...fields, recurrence, recurrenceSeriesId, recurrenceDate, recurrenceRevision, updatedAt: writeTimestamp } })
    .returning()
  if (task === undefined) throw new Error(`upsert of task ${id} returned no row`)
  return task
}

/** The live (not soft-deleted) task with this id, or undefined. */
export async function findTask(db: Db, id: string): Promise<TaskRow | undefined> {
  const [task] = await db
    .select()
    .from(tasks)
    .where(and(eq(tasks.id, id), isNull(tasks.deletedAt)))
    .limit(1)
  return task
}

/** Like `findTask` but throws 404. */
export async function getTask(db: Db, id: string): Promise<TaskRow> {
  const task = await findTask(db, id)
  if (task === undefined) throw notFound(`task ${id}`)
  return task
}

/** Applies the defined fields of `patch` over the stored task. Throws 404 for unknown or deleted ids. */
export async function patchTask(db: Db, id: string, patch: TaskPatch, now: Date = new Date()): Promise<TaskRow> {
  return db.transaction(async (tx) => {
    await lockTaskRecurrences(tx)
    const current = await getTask(tx, id)
    const keep = <T>(next: T | undefined, stored: T): T => (next === undefined ? stored : next)
    const iso = (d: Date | null): string | null => (d === null ? null : d.toISOString())
    const body: TaskBody = {
      categoryId: keep(patch.categoryId, current.categoryId),
      title: keep(patch.title, current.title),
      notes: keep(patch.notes, current.notes),
      source: keep(patch.source, current.source),
      durationMinutes: keep(patch.durationMinutes, current.durationMinutes),
      minChunkMinutes: keep(patch.minChunkMinutes, current.minChunkMinutes),
      priority: keep(patch.priority, current.priority),
      deadlineType: keep(patch.deadlineType, current.deadlineType),
      dueAt: keep(patch.dueAt, iso(current.dueAt)),
      ...(patch.someday === undefined ? {} : { someday: patch.someday }),
      startAt: keep(patch.startAt, iso(current.startAt)),
      scheduleId: keep(patch.scheduleId, current.scheduleId),
      context: keep(patch.context, current.context),
      projectId: keep(patch.projectId, current.projectId),
      attention: keep(patch.attention, current.attention),
      pinnedStart: keep(patch.pinnedStart, iso(current.pinnedStart)),
      recurrence: keep(patch.recurrence, current.recurrence),
      // A targeted edit without a precondition (e.g. MCP) explicitly acts on the latest row.
      expectedRecurrenceRevision: keep(patch.expectedRecurrenceRevision, current.recurrenceRevision),
      completedMinutes: keep(patch.completedMinutes, current.completedMinutes),
      completedAt: keep(patch.completedAt, iso(current.completedAt)),
    }
    return writeTask(tx, id, body, now)
  })
}

/** Marks a task done now, crediting its full duration. Already-completed tasks are returned unchanged. */
export async function completeTask(db: Db, id: string, now: Date = new Date()): Promise<TaskRow> {
  return db.transaction(async (tx) => {
    await lockTaskRecurrences(tx)
    const current = await getTask(tx, id)
    if (current.completedAt !== null) return current
    const [task] = await tx
      .update(tasks)
      .set({ completedAt: now, completedMinutes: current.durationMinutes, updatedAt: writeTimestamp })
      .where(eq(tasks.id, id))
      .returning()
    if (task === undefined) throw notFound(`task ${id}`)
    return task
  })
}

/** Tombstones a task so sync clients see the deletion. Throws 404 when the id never existed. */
export async function softDeleteTask(db: Db, id: string, now: Date = new Date()): Promise<void> {
  await db.transaction(async (tx) => {
    await lockTaskRecurrences(tx)
    const [task] = await tx.select().from(tasks).where(eq(tasks.id, id))
    if (task === undefined) throw notFound(`task ${id}`)
    const revision = await stopRecurrence(tx, task, now)
    await tx.update(tasks).set({ deletedAt: now, updatedAt: writeTimestamp, recurrenceRevision: revision ?? task.recurrenceRevision }).where(eq(tasks.id, id))
  })
}

/** Stop future repeats; past unfinished tasks remain independent one-offs, and history stays intact. */
async function stopRecurrence(db: Db, task: TaskRow, now: Date): Promise<string | null> {
  if (task.recurrenceSeriesId === null || task.recurrenceDate === null) return null
  const revision = randomUUID()
  const [stopped] = await db.update(taskRecurrences).set({ deletedAt: now, updatedAt: writeTimestamp, revision }).where(and(
    eq(taskRecurrences.id, task.recurrenceSeriesId), isNull(taskRecurrences.deletedAt),
  )).returning()
  if (stopped === undefined) return null
  await db.update(tasks).set({ deletedAt: now, updatedAt: writeTimestamp, recurrenceRevision: revision }).where(and(
    eq(tasks.recurrenceSeriesId, task.recurrenceSeriesId), gt(tasks.recurrenceDate, task.recurrenceDate),
    isNull(tasks.completedAt), isNull(tasks.deletedAt),
  ))
  await db.update(tasks).set({ recurrence: null, recurrenceSeriesId: null, recurrenceDate: null, recurrenceRevision: revision, updatedAt: writeTimestamp }).where(and(
    eq(tasks.recurrenceSeriesId, task.recurrenceSeriesId), ne(tasks.id, task.id),
    isNull(tasks.completedAt), isNull(tasks.deletedAt),
  ))
  return revision
}

/** Called in the scheduler transaction. No backfill after downtime and no duplicate occurrences. */
export async function materializeRecurringTasks(db: Db, now: Date, horizonDays: number): Promise<void> {
  await lockTaskRecurrences(db)
  const seriesRows = await db.select().from(taskRecurrences).where(isNull(taskRecurrences.deletedAt))
  for (const series of seriesRows) {
    const today = localDay(now, series.rule.timeZone)
    const from = series.fromDate > today ? series.fromDate : today
    const dates = occurrenceDates(series.rule, from, addCalendarDays(today, horizonDays))
    const existing = await db.select().from(tasks).where(and(
      eq(tasks.recurrenceSeriesId, series.id), gte(tasks.recurrenceDate, from),
    ))
    const byDate = new Map(existing.map((task) => [task.recurrenceDate, task]))
    const inserts: (typeof tasks.$inferInsert)[] = []
    for (const date of dates) {
      const current = byDate.get(date)
      if (current !== undefined && (current.deletedAt === null || current.completedAt !== null)) continue
      const fields = {
        ...occurrenceFields(series.template, series.rule, date),
        recurrence: series.rule,
        recurrenceSeriesId: series.id,
        recurrenceDate: date,
        recurrenceRevision: series.revision,
        updatedAt: now,
        deletedAt: null,
      }
      if (current === undefined) inserts.push({ id: randomUUID(), ...fields })
      else await db.update(tasks).set({ ...fields, updatedAt: writeTimestamp }).where(eq(tasks.id, current.id))
    }
    if (inserts.length > 0) await db.insert(tasks).values(inserts.map((row) => ({ ...row, updatedAt: writeTimestamp }))).onConflictDoNothing()
  }
}

/** Category deletion must move the template too, or future occurrences would recreate the old category. */
export async function moveRecurringTaskCategory(db: Db, from: string, to: string, now: Date): Promise<void> {
  await lockTaskRecurrences(db)
  const rows = await db.select().from(taskRecurrences).where(and(
    isNull(taskRecurrences.deletedAt), eq(sql`${taskRecurrences.template}->>'categoryId'`, from),
  ))
  for (const row of rows) {
    await db.update(taskRecurrences).set({ template: { ...row.template, categoryId: to }, updatedAt: writeTimestamp }).where(eq(taskRecurrences.id, row.id))
  }
}
