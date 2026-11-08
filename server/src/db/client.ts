import type { PgDatabase, PgQueryResultHKT } from 'drizzle-orm/pg-core'
import { drizzle } from 'drizzle-orm/postgres-js'
import postgres from 'postgres'
import * as schema from './schema.js'

/** Any Drizzle Postgres database over our schema: postgres.js in production, PGlite in tests. */
export type Db = PgDatabase<PgQueryResultHKT, typeof schema>

export interface ProductionDb {
  db: Db
  close: () => Promise<void>
}

export function createDb(url: string): ProductionDb {
  // Neon's pooled endpoint runs PgBouncer in transaction mode, which cannot use named prepared statements.
  const client = postgres(url, { prepare: false, max: 5, idle_timeout: 20 })
  return {
    db: drizzle(client, { schema }),
    close: () => client.end(),
  }
}

export { schema }
