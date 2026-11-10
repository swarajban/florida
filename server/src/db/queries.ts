import { and, eq, isNull, lte, sql } from 'drizzle-orm'
import type { Db } from './client.js'
import { categories, projects, schedules, settings, tasks } from './schema.js'

/** The seeded category new and orphaned tasks land in; it cannot be renamed or deleted. */
export const INBOX_CATEGORY_ID = 'inbox'

/** Id of the only `settings` row. */
export const SETTINGS_ID = 'default'

/** Id of the only `plan_summary` row. */
export const PLAN_SUMMARY_ID = 'default'

/** True when a live (not soft-deleted) category has this id. */
export async function categoryExists(db: Db, id: string): Promise<boolean> {
  const rows = await db
    .select({ id: categories.id })
    .from(categories)
    .where(and(eq(categories.id, id), isNull(categories.deletedAt)))
    .limit(1)
  return rows.length > 0
}

/** True when a live (not soft-deleted) schedule has this id. */
export async function scheduleExists(db: Db, id: string): Promise<boolean> {
  const rows = await db
    .select({ id: schedules.id })
    .from(schedules)
    .where(and(eq(schedules.id, id), isNull(schedules.deletedAt)))
    .limit(1)
  return rows.length > 0
}

/** True when a live (not soft-deleted) project has this id. */
export async function projectExists(db: Db, id: string): Promise<boolean> {
  const rows = await db
    .select({ id: projects.id })
    .from(projects)
    .where(and(eq(projects.id, id), isNull(projects.deletedAt)))
    .limit(1)
  return rows.length > 0
}

/** The routine's time zone, which is also the user's home zone when a client gives none; UTC until seeded. */
export async function defaultTimeZone(db: Db): Promise<string> {
  const [row] = await db.select({ timeZone: settings.timeZone }).from(settings).limit(1)
  return row?.timeZone ?? 'UTC'
}

/**
 * Live categories in display order, each with up to `perCategory` distinct titles of its live
 * tasks: open tasks first (newest first), then completed ones (most recently completed first). A
 * repeated title ("Pay rent" every month) takes one slot, at the position of its best-ranked task.
 */
export async function categoriesWithExamples(
  db: Db,
  perCategory = 8,
): Promise<{ id: string; name: string; examples: string[] }[]> {
  const rows = await db
    .select({ id: categories.id, name: categories.name })
    .from(categories)
    .where(isNull(categories.deletedAt))
    .orderBy(categories.sortOrder, categories.name)
  const ranked = db
    .select({
      categoryId: tasks.categoryId,
      title: tasks.title,
      rank: sql<number>`row_number() over (partition by ${tasks.categoryId} order by ${tasks.completedAt} desc nulls first, ${tasks.createdAt} desc, ${tasks.id})`.as(
        'rank',
      ),
    })
    .from(tasks)
    .where(isNull(tasks.deletedAt))
    .as('ranked')
  const distinctTitles = db
    .select({ categoryId: ranked.categoryId, title: ranked.title, rank: sql<number>`min(${ranked.rank})`.as('rank') })
    .from(ranked)
    .groupBy(ranked.categoryId, ranked.title)
    .as('distinct_titles')
  const reranked = db
    .select({
      categoryId: distinctTitles.categoryId,
      title: distinctTitles.title,
      rank: sql<number>`row_number() over (partition by ${distinctTitles.categoryId} order by ${distinctTitles.rank})`.as('rank'),
    })
    .from(distinctTitles)
    .as('reranked')
  const examples = await db
    .select({ categoryId: reranked.categoryId, title: reranked.title })
    .from(reranked)
    .where(lte(reranked.rank, perCategory))
    .orderBy(reranked.categoryId, reranked.rank)
  return rows.map((p) => ({ ...p, examples: examples.filter((e) => e.categoryId === p.id).map((e) => e.title) }))
}
