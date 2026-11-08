import { fileURLToPath } from 'node:url'
import { drizzle } from 'drizzle-orm/postgres-js'
import { migrate } from 'drizzle-orm/postgres-js/migrator'
import postgres from 'postgres'

// Works from both src/ (tsx) and dist/ (node): the migrations folder is a sibling of either.
const migrationsFolder = fileURLToPath(new URL('../drizzle', import.meta.url))

const url = process.env.DATABASE_URL
if (url === undefined || url === '') {
  console.error('DATABASE_URL is required')
  process.exit(1)
}

const client = postgres(url, { max: 1, prepare: false })
try {
  await migrate(drizzle(client), { migrationsFolder })
  console.log(`[migrate] migrations from ${migrationsFolder} applied`)
} finally {
  await client.end()
}
