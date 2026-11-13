import { and, eq, isNull, sql } from 'drizzle-orm'
import { z } from 'zod'
import { writeTimestamp } from './db/sync-clock.js'
import type { Db } from './db/client.js'
import { categoryExists } from './db/queries.js'
import { dayOverrides, projectPlacements, projects, taskRecurrences, tasks } from './db/schema.js'
import type { DayOverrideRow, ProjectRow } from './db/schema.js'
import { lockTaskRecurrences } from './tasks.js'
import { badRequest, calendarDate, notFound } from './validation.js'

export const projectStatus = z.enum(['thinking', 'active', 'on_hold', 'done'])

/** Full project body as accepted by `PUT /api/projects/:id` and the MCP tools. */
export const projectBody = z.object({
  name: z.string().min(1),
  status: projectStatus
    .optional()
    .describe('thinking (an idea), active (being worked on; the only status that is scheduled), on_hold, or done. Defaults to active.'),
  categoryId: z.string().min(1).nullish().describe('The category the project belongs to, which gives it its color and area'),
  notes: z.string().nullish(),
  nextStep: z.string().nullish().describe('One line: what happens next on this project'),
  parallel: z
    .boolean()
    .optional()
    .describe('True when the work mostly runs itself (an agent does it): its tasks may be planned beside other parallel projects.'),
  weeklyMinutes: z
    .number()
    .int()
    .min(0)
    .max(7 * 24 * 60)
    .nullish()
    .describe('Minutes to reserve for the project each week; the scheduler adds project time for what its tasks do not cover.'),
  sortOrder: z.number().int().nullish(),
})
export type ProjectBody = z.infer<typeof projectBody>

/** Partial project body: absent fields keep their stored value, `null` clears a nullable field. */
export const projectPatch = projectBody.partial()
export type ProjectPatch = z.infer<typeof projectPatch>

/** Creates or replaces a project. Undeletes a tombstoned id. Throws 400 for an unknown category. */
export async function upsertProject(db: Db, id: string, body: ProjectBody, now: Date = new Date()): Promise<ProjectRow> {
  if (body.categoryId != null && !(await categoryExists(db, body.categoryId))) {
    throw badRequest(`unknown categoryId ${body.categoryId}`)
  }
  const [current] = await db.select().from(projects).where(eq(projects.id, id))
  const fields = {
    name: body.name,
    status: body.status ?? current?.status ?? 'active',
    categoryId: body.categoryId ?? null,
    notes: body.notes ?? null,
    nextStep: body.nextStep ?? null,
    parallel: body.parallel ?? current?.parallel ?? false,
    weeklyMinutes: body.weeklyMinutes ?? null,
    sortOrder: body.sortOrder ?? current?.sortOrder ?? 0,
    updatedAt: writeTimestamp,
    deletedAt: null,
  }
  const [project] = await db
    .insert(projects)
    .values({ id, ...fields })
    .onConflictDoUpdate({ target: projects.id, set: fields })
    .returning()
  if (project === undefined) throw new Error(`upsert of project ${id} returned no row`)
  return project
}

/** The live project with this id; throws 404 otherwise. */
export async function getProject(db: Db, id: string): Promise<ProjectRow> {
  const [project] = await db
    .select()
    .from(projects)
    .where(and(eq(projects.id, id), isNull(projects.deletedAt)))
  if (project === undefined) throw notFound(`project ${id}`)
  return project
}

/** Applies the defined fields of `patch` over the stored project. Throws 404 for unknown or deleted ids. */
export async function patchProject(db: Db, id: string, patch: ProjectPatch, now: Date = new Date()): Promise<ProjectRow> {
  const current = await getProject(db, id)
  const keep = <T>(next: T | undefined, stored: T): T => (next === undefined ? stored : next)
  return upsertProject(
    db,
    id,
    {
      name: keep(patch.name, current.name),
      status: keep(patch.status, current.status),
      categoryId: keep(patch.categoryId, current.categoryId),
      notes: keep(patch.notes, current.notes),
      nextStep: keep(patch.nextStep, current.nextStep),
      parallel: keep(patch.parallel, current.parallel),
      weeklyMinutes: keep(patch.weeklyMinutes, current.weeklyMinutes),
      sortOrder: keep(patch.sortOrder, current.sortOrder),
    },
    now,
  )
}

/**
 * Tombstones a project. Its tasks stay, without a project, so they are scheduled like any other
 * task; a repeating task's template lets go of it too, or later occurrences would point at the
 * tombstone. Its project time goes at once, the hours already spent included: sync sends that
 * table whole, and nothing counts a deleted project's week. Throws 404 when the id never existed.
 */
export async function softDeleteProject(db: Db, id: string, now: Date = new Date()): Promise<void> {
  await db.transaction(async (tx) => {
    await lockTaskRecurrences(tx)
    const deleted = await tx
      .update(projects)
      .set({ deletedAt: now, updatedAt: writeTimestamp })
      .where(eq(projects.id, id))
      .returning({ id: projects.id })
    if (deleted.length === 0) throw notFound(`project ${id}`)
    await tx.delete(projectPlacements).where(eq(projectPlacements.projectId, id))
    await tx.update(tasks).set({ projectId: null, updatedAt: writeTimestamp }).where(eq(tasks.projectId, id))
    const series = await tx
      .select()
      .from(taskRecurrences)
      .where(eq(sql`${taskRecurrences.template}->>'projectId'`, id))
    for (const row of series) {
      await tx
        .update(taskRecurrences)
        .set({ template: { ...row.template, projectId: null }, updatedAt: writeTimestamp })
        .where(eq(taskRecurrences.id, row.id))
    }
  })
}

/** Body of `PUT /api/day-overrides/:date`. */
export const dayOverrideBody = z.object({
  kind: z
    .enum(['home', 'office', 'off'])
    .describe('home: work from home that day. office: go in. off: nothing is planned and there is no gym.'),
  note: z.string().nullish(),
})
export type DayOverrideBody = z.infer<typeof dayOverrideBody>

/** Sets what one date is, replacing an earlier override of it. `date` is "YYYY-MM-DD". */
export async function setDayOverride(db: Db, date: string, body: DayOverrideBody, now: Date = new Date()): Promise<DayOverrideRow> {
  const key = calendarDate.parse(date)
  const fields = { kind: body.kind, note: body.note ?? null, updatedAt: writeTimestamp, deletedAt: null }
  const [row] = await db
    .insert(dayOverrides)
    .values({ date: key, ...fields })
    .onConflictDoUpdate({ target: dayOverrides.date, set: fields })
    .returning()
  if (row === undefined) throw new Error(`upsert of day override ${key} returned no row`)
  return row
}

/** Puts a date back on its weekday's routine. Throws 404 when it never had an override. */
export async function clearDayOverride(db: Db, date: string, now: Date = new Date()): Promise<void> {
  const deleted = await db
    .update(dayOverrides)
    .set({ deletedAt: now, updatedAt: writeTimestamp })
    .where(eq(dayOverrides.date, date))
    .returning({ date: dayOverrides.date })
  if (deleted.length === 0) throw notFound(`day override ${date}`)
}
