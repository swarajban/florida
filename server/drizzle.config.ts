import { defineConfig } from 'drizzle-kit'

// `drizzle-kit generate` only reads the schema; the URL is used by `drizzle-kit migrate`/`studio`.
export default defineConfig({
  dialect: 'postgresql',
  schema: './src/db/schema.ts',
  out: './drizzle',
  dbCredentials: {
    url: process.env.DATABASE_URL ?? 'postgres://localhost:5432/florida',
  },
})
