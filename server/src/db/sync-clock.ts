import { sql } from 'drizzle-orm'
import type { Db } from './client.js'

export const writeTimestamp = sql<Date>`date_trunc('milliseconds', clock_timestamp())`

export async function syncCursor(db: Db): Promise<Date> {
  const [row] = await db.select({
    cursor: sql<string>`to_char(
      (least(statement_timestamp(), min(xact_start)) - interval '1 millisecond') at time zone 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
    )`,
  }).from(sql`pg_stat_activity`)
    .where(sql`datname = current_database() and backend_type = 'client backend' and pid <> pg_backend_pid()`)
  if (row === undefined) throw new Error('Could not obtain a sync cursor')
  return new Date(row.cursor)
}
