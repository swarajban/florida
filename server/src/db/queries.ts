import { and, eq, isNull } from 'drizzle-orm'
import type { Db } from './client.js'
import { categories, schedules } from './schema.js'

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

/** The user's home time zone when a client gives none: the oldest live schedule's zone, else UTC. */
export async function defaultTimeZone(db: Db): Promise<string> {
  const [schedule] = await db
    .select({ timeZone: schedules.timeZone })
    .from(schedules)
    .where(isNull(schedules.deletedAt))
    .orderBy(schedules.createdAt)
    .limit(1)
  return schedule?.timeZone ?? 'UTC'
}
