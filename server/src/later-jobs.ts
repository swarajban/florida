import { DAY } from '@florida/scheduler'
import { and, eq, isNull, lt } from 'drizzle-orm'
import type { Db } from './db/client.js'
import { laterItems } from './db/schema.js'
import { writeTimestamp } from './db/sync-clock.js'
import { unreadLater } from './later.js'
import { fetchLaterMetadata } from './later-metadata.js'

export async function archiveStaleLater(db: Db, now = new Date()): Promise<boolean> {
  const archived = await db.update(laterItems).set({ archivedAt: now, updatedAt: writeTimestamp })
    .where(and(unreadLater, lt(laterItems.savedAt, new Date(now.getTime() - 30 * DAY))))
    .returning({ id: laterItems.id })
  return archived.length > 0
}

export async function enrichLaterBatch(db: Db, fetchMetadata = fetchLaterMetadata): Promise<boolean> {
  const livePending = and(isNull(laterItems.deletedAt), isNull(laterItems.archivedAt), isNull(laterItems.enrichedAt))!
  try {
    const queue = await db.select().from(laterItems).where(livePending)
      .orderBy(laterItems.savedAt, laterItems.id).limit(4)
    const written = await Promise.all(queue.map(async (item) => {
      const enriched = await fetchMetadata(item)
      return db.update(laterItems).set({ ...enriched, enrichedAt: writeTimestamp, updatedAt: writeTimestamp })
        .where(and(eq(laterItems.id, item.id), livePending)).returning({ id: laterItems.id })
    }))
    return written.some((rows) => rows.length > 0)
  } catch {
    throw new Error('Could not enrich Later items')
  }
}
