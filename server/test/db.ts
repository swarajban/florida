import { fileURLToPath } from 'node:url'
import { PGlite } from '@electric-sql/pglite'
import { drizzle } from 'drizzle-orm/pglite'
import { migrate } from 'drizzle-orm/pglite/migrator'
import type { Db } from '../src/db/client.js'
import * as schema from '../src/db/schema.js'

export interface TestDb {
  db: Db
  close: () => Promise<void>
}

/** In-process Postgres with the committed migrations applied. */
export async function createTestDb(): Promise<TestDb> {
  const client = new PGlite()
  const db = drizzle(client, { schema })
  await migrate(db, { migrationsFolder: fileURLToPath(new URL('../drizzle', import.meta.url)) })
  return { db, close: () => client.close() }
}
