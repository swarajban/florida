import { and, eq, isNull } from 'drizzle-orm'
import { z } from 'zod'
import type { Db } from './db/client.js'
import { projectExists, scheduleExists } from './db/queries.js'
import { tasks } from './db/schema.js'
import type { TaskRow } from './db/schema.js'
import { badRequest, isoInstant, notFound, toDate } from './validation.js'

export const priority = z.enum(['asap', 'high', 'medium', 'low'])
export const deadlineType = z.enum(['hard', 'soft', 'none'])

/** Full task body as accepted by `PUT /api/tasks/:id` and the MCP tools. */
export const taskBody = z.object({
  projectId: z.string().min(1),
  title: z.string().min(1),
  notes: z.string().nullish(),
  durationMinutes: z.number().int().min(1),
  minChunkMinutes: z.number().int().min(1).nullish(),
  priority,
  deadlineType,
  dueAt: isoInstant.nullish(),
  startAt: isoInstant.nullish(),
  scheduleId: z.string().min(1).nullish(),
  pinnedStart: isoInstant.nullish(),
  completedMinutes: z.number().int().min(0).nullish(),
  completedAt: isoInstant.nullish(),
})
export type TaskBody = z.infer<typeof taskBody>

/** Partial task body: absent fields keep their stored value, `null` clears a nullable field. */
export const taskPatch = taskBody.partial()
export type TaskPatch = z.infer<typeof taskPatch>

/** Creates or replaces a task. Undeletes a tombstoned id. Throws 400 for unknown references. */
export async function upsertTask(db: Db, id: string, body: TaskBody, now: Date = new Date()): Promise<TaskRow> {
  if (!(await projectExists(db, body.projectId))) throw badRequest(`unknown projectId ${body.projectId}`)
  if (body.scheduleId != null && !(await scheduleExists(db, body.scheduleId))) {
    throw badRequest(`unknown scheduleId ${body.scheduleId}`)
  }
  const fields = {
    projectId: body.projectId,
    title: body.title,
    notes: body.notes ?? null,
    durationMinutes: body.durationMinutes,
    minChunkMinutes: body.minChunkMinutes ?? null,
    priority: body.priority,
    deadlineType: body.deadlineType,
    dueAt: toDate(body.dueAt),
    startAt: toDate(body.startAt),
    scheduleId: body.scheduleId ?? null,
    pinnedStart: toDate(body.pinnedStart),
    completedMinutes: body.completedMinutes ?? 0,
    completedAt: toDate(body.completedAt),
    updatedAt: now,
    deletedAt: null,
  }
  const [task] = await db
    .insert(tasks)
    .values({ id, ...fields })
    .onConflictDoUpdate({ target: tasks.id, set: fields })
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
  const current = await getTask(db, id)
  const keep = <T>(next: T | undefined, stored: T): T => (next === undefined ? stored : next)
  const iso = (d: Date | null): string | null => (d === null ? null : d.toISOString())
  const body: TaskBody = {
    projectId: keep(patch.projectId, current.projectId),
    title: keep(patch.title, current.title),
    notes: keep(patch.notes, current.notes),
    durationMinutes: keep(patch.durationMinutes, current.durationMinutes),
    minChunkMinutes: keep(patch.minChunkMinutes, current.minChunkMinutes),
    priority: keep(patch.priority, current.priority),
    deadlineType: keep(patch.deadlineType, current.deadlineType),
    dueAt: keep(patch.dueAt, iso(current.dueAt)),
    startAt: keep(patch.startAt, iso(current.startAt)),
    scheduleId: keep(patch.scheduleId, current.scheduleId),
    pinnedStart: keep(patch.pinnedStart, iso(current.pinnedStart)),
    completedMinutes: keep(patch.completedMinutes, current.completedMinutes),
    completedAt: keep(patch.completedAt, iso(current.completedAt)),
  }
  return upsertTask(db, id, body, now)
}

/** Marks a task done now, crediting its full duration. Already-completed tasks are returned unchanged. */
export async function completeTask(db: Db, id: string, now: Date = new Date()): Promise<TaskRow> {
  const current = await getTask(db, id)
  if (current.completedAt !== null) return current
  const [task] = await db
    .update(tasks)
    .set({ completedAt: now, completedMinutes: current.durationMinutes, updatedAt: now })
    .where(eq(tasks.id, id))
    .returning()
  if (task === undefined) throw notFound(`task ${id}`)
  return task
}

/** Tombstones a task so sync clients see the deletion. Throws 404 when the id never existed. */
export async function softDeleteTask(db: Db, id: string, now: Date = new Date()): Promise<void> {
  const deleted = await db
    .update(tasks)
    .set({ deletedAt: now, updatedAt: now })
    .where(eq(tasks.id, id))
    .returning({ id: tasks.id })
  if (deleted.length === 0) throw notFound(`task ${id}`)
}
