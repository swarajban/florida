import { sql } from 'drizzle-orm'
import type { Db } from './client.js'

export const writeTimestamp = sql<Date>`date_trunc('milliseconds', clock_timestamp())`

let lastFenceWarningAt = -Infinity

export async function syncCursor(db: Db): Promise<Date> {
  const bound = sql`least(statement_timestamp(), min(xact_start))`
  const [row] = await db.select({
    cursor: sql<string>`to_char(
      (${bound} - interval '1 millisecond') at time zone 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
    )`,
    lagMs: sql<number>`extract(epoch from (statement_timestamp() - ${bound})) * 1000`.mapWith(Number),
  }).from(sql`pg_stat_activity`)
    .where(sql`datname = current_database() and backend_type = 'client backend' and pid <> pg_backend_pid()`)
  if (row === undefined) throw new Error('Could not obtain a sync cursor')
  const now = performance.now()
  if (row.lagMs >= 60_000 && now - lastFenceWarningAt >= 60_000) {
    lastFenceWarningAt = now
    console.warn(`[sync] an open transaction is holding the cursor back by ${Math.floor(row.lagMs)}ms; cursor=${row.cursor}`)
  }
  return new Date(row.cursor)
}
