import { fileURLToPath } from 'node:url'
import { drizzle } from 'drizzle-orm/postgres-js'
import { migrate } from 'drizzle-orm/postgres-js/migrator'
import postgres from 'postgres'
import * as schema from './db/schema.js'
import { seed } from './seed.js'

// Works from both src/ (tsx) and dist/ (node): the migrations folder is a sibling of either.
const migrationsFolder = fileURLToPath(new URL('../drizzle', import.meta.url))

const url = process.env.DATABASE_URL
if (url === undefined || url === '') {
  console.error('DATABASE_URL is required')
  process.exit(1)
}

const client = postgres(url, { max: 1, prepare: false })
try {
  const db = drizzle(client, { schema })
  await migrate(db, { migrationsFolder })
  console.log(`[migrate] migrations from ${migrationsFolder} applied`)
  // The scheduler needs the settings row and the routine; a release that adds a table must also fill it.
  await seed(db)
  console.log('[migrate] seed ensured')
} finally {
  await client.end()
}
