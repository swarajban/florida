import { readFileSync } from 'node:fs'
import { sql } from 'drizzle-orm'
import { expect, it } from 'vitest'
import type { Db } from '../src/db/client.js'
import { laterItems, tasks } from '../src/db/schema.js'
import { saveLater, setLaterState } from '../src/later.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'

const conversion = sql.raw(readFileSync(new URL('../drizzle/0017_convert-later-link-tasks.sql', import.meta.url), 'utf8'))
const factory = { title: 'Agent Readiness Reports | Factory', url: 'https://factory.com/agent-readiness' }
const notion = { title: 'A new shape for work', url: 'https://www.notion.com/a-new-shape-for-work' }
const createdAt = new Date('2026-11-19T00:00:00Z')
const task = (id: string, { title, url }: typeof factory): typeof tasks.$inferInsert => ({
  id, title, source: { url, title, kind: 'web' }, createdAt,
  categoryId: 'inbox', durationMinutes: 15, priority: 'medium', deadlineType: 'none',
})

async function applyTwice(db: Db) {
  const state = async () => ({
    items: await db.select().from(laterItems).orderBy(laterItems.id),
    tasks: await db.select().from(tasks).orderBy(tasks.id),
  })
  await db.execute(conversion)
  const once = await state()
  await db.execute(conversion)
  expect(await state()).toEqual(once)
  return once
}

it('converts only the matching title and URL pairs, safely reusing a previously saved link', async () => {
  const { db, close } = await createTestDb()
  try {
    await seed(db)
    await db.insert(tasks).values([
      task('factory', factory), task('notion', notion),
      task('title-only', { ...factory, url: 'https://example.com' }),
      task('url-only', { ...notion, title: 'Review the Notion site' }),
      { ...task('with-notes', notion), notes: 'Keep this task' },
    ])
    await saveLater(db, 'existing', { ...notion, source: 'manual' })
    const existing = await setLaterState(db, 'existing', { action: 'read' })
    const result = await applyTwice(db)
    expect(result.items).toEqual([existing, expect.objectContaining({
      id: 'later:task:factory', title: factory.title, url: factory.url, savedAt: createdAt, archivedAt: null, readAt: null,
    })])
    expect(result.tasks.filter((row) => row.deletedAt !== null).map((row) => row.id)).toEqual(['factory', 'notion'])
  } finally {
    await close()
  }
})

const snapshotPath = process.env.LATER_CONVERSION_SNAPSHOT
it.runIf(snapshotPath !== undefined)('dry-runs the release SQL against a read-only snapshot copied into PGlite', async () => {
  const snapshot = JSON.parse(readFileSync(snapshotPath!, 'utf8')) as {
    laterAvailable: boolean
    targets: { id: string; title: string; source: { url: string }; createdAt: string; deletedAt: null; completedAt: null;
      recurrence: null; recurrenceSeriesId: null; notes: null }[]
    laterCandidates: unknown[]
  }
  expect(snapshot).toMatchObject({ laterAvailable: true, laterCandidates: [] })
  expect(snapshot.targets).toHaveLength(2)
  const { db, close } = await createTestDb()
  try {
    await seed(db)
    await db.insert(tasks).values(snapshot.targets.map(({ source, createdAt, ...row }) => ({
      ...task(row.id, { title: row.title, url: source.url }), ...row, createdAt: new Date(createdAt),
    })))
    const result = await applyTwice(db)
    expect(result.items.map(({ title, url }) => ({ title, url })).sort((a, b) => a.title.localeCompare(b.title))).toEqual([notion, factory])
    expect(result.tasks.every(({ deletedAt }) => deletedAt instanceof Date)).toBe(true)
  } finally {
    await close()
  }
})
