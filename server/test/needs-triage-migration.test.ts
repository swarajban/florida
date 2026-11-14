import { readFileSync } from 'node:fs'
import { setTimeout as sleep } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { PGlite } from '@electric-sql/pglite'
import { readMigrationFiles } from 'drizzle-orm/migrator'
import { drizzle } from 'drizzle-orm/pglite'
import { describe, expect, it } from 'vitest'
import { createApp } from '../src/app.js'
import * as schema from '../src/db/schema.js'
import { occurrenceFields } from '../src/recurrence.js'
import type { RecurrenceRule } from '../src/recurrence.js'
import { buildSchedulerInput, runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { materializeRecurringTasks, upsertTask } from '../src/tasks.js'
import { FakeSync, testConfig as config } from './fixtures.js'

const fixture = JSON.parse(readFileSync(new URL('./fixtures/needs-triage-production-shape.json', import.meta.url), 'utf8')) as {
  categories: { id: string; deletedAt: string | null }[]
  tasks: { id: string; categoryId: string; dueAt: string | null; startAt: string | null; pinnedStart: string | null; deadlineType: 'none' | 'soft' | 'hard'; completedAt: string | null; deletedAt: string | null; updatedAt: string; recurrenceSeriesId: false }[]
}

async function beforeMigration() {
  const client = new PGlite()
  const migrations = readMigrationFiles({ migrationsFolder: fileURLToPath(new URL('../drizzle', import.meta.url)) })
  const index = migrations.findIndex((migration) => migration.sql.some((statement) => statement.includes('ADD COLUMN "someday"')))
  expect(index).toBeGreaterThan(0)
  for (const migration of migrations.slice(0, index)) {
    for (const statement of migration.sql) await client.exec(statement)
  }
  const db = drizzle(client, { schema })
  await seed(db)
  return {
    client,
    db,
    migrate: () => client.transaction(async (tx) => {
      for (const statement of migrations[index]!.sql) await tx.exec(statement)
    }),
  }
}

describe('Someday migration', () => {
  it('preserves date intent from generated occurrences of raw null-date templates when extending the horizon', async () => {
    const { client, db, migrate } = await beforeMigration()
    try {
      const now = new Date('2028-01-31T16:00:00Z')
      const rule: RecurrenceRule = { frequency: 'month', interval: 1, timeZone: 'America/Los_Angeles', startDate: '2028-01-31' }
      const template = {
        anchorDate: rule.startDate, categoryId: 'work', title: 'Series', notes: null, durationMinutes: 30,
        minChunkMinutes: null, priority: 'medium' as const, deadlineType: 'soft' as const, dueAt: null, startAt: null,
        scheduleId: null, context: 'computer' as const, projectId: null, attention: null, pinnedStart: null,
      }
      const generated = occurrenceFields({ ...template, someday: false }, rule, rule.startDate)
      for (const id of ['materialized', 'undated']) {
        await client.query(`insert into task_recurrences (id, revision, rule, template, from_date)
          values ($1, $1, $2, $3, $4)`, [id, JSON.stringify(rule), JSON.stringify(template), rule.startDate])
        await client.query(`insert into tasks (id, category_id, title, duration_minutes, priority, deadline_type, due_at, start_at,
          recurrence, recurrence_series_id, recurrence_date, recurrence_revision)
          values ($1, 'work', $1, 30, 'medium', 'soft', $2, $3, $4, $5, $6, $5)`,
        [`${id}-existing`, id === 'materialized' ? generated.dueAt?.toISOString() : null,
          id === 'materialized' ? generated.startAt.toISOString() : null, JSON.stringify(rule), id, rule.startDate])
      }
      await migrate()
      const templates = await db.select().from(schema.taskRecurrences)
      expect(templates.find((row) => row.id === 'materialized')?.template).toMatchObject({ someday: false, dueAt: null, startAt: null, pinnedStart: null })
      expect(templates.find((row) => row.id === 'undated')?.template.someday).toBe(true)
      const result = await runScheduling(db, { HORIZON_DAYS: 125 }, now)
      const rows = await db.select().from(schema.tasks)
      const active = rows.filter((task) => task.recurrenceSeriesId === 'materialized')
      const deferred = rows.filter((task) => task.recurrenceSeriesId === 'undated')
      expect(active.length).toBeGreaterThan(1)
      expect(deferred.length).toBeGreaterThan(1)
      expect(active.every((task) => !task.someday && task.dueAt !== null && task.startAt !== null)).toBe(true)
      expect(deferred.every((task) => task.someday && task.dueAt === null && task.pinnedStart === null)).toBe(true)
      expect(active.find((task) => task.id === 'materialized-existing')).toMatchObject({ dueAt: generated.dueAt, startAt: generated.startAt })
      const input = buildSchedulerInput({ now, horizonDays: 125, timeZone: rule.timeZone,
        routineBlocks: await db.select().from(schema.routineBlocks), categories: await db.select().from(schema.categories), tasks: rows, events: [] })
      expect(input.tasks.map((task) => task.id).sort()).toEqual(active.map((task) => task.id).sort())
      expect(result.placements.some((block) => block.taskId === 'materialized-existing')).toBe(true)
      expect(result.placements.some((block) => active.some((task) => task.id === block.taskId && task.id !== 'materialized-existing'))).toBe(true)
      for (const artifacts of [result.placements, result.optional, result.unscheduled, result.late]) {
        expect(artifacts.some((artifact) => deferred.some((task) => task.id === artifact.taskId))).toBe(false)
      }
    } finally {
      await client.close()
    }
  })

  it('uses any linked due, start or pin as template date intent, including completed and tombstoned history', async () => {
    const { client, db, migrate } = await beforeMigration()
    try {
      const rule: RecurrenceRule = { frequency: 'month', interval: 1, timeZone: 'America/Los_Angeles', startDate: '2028-01-31' }
      const instant = '2028-01-31T18:00:00Z'
      const cases = [
        { id: 'due-history', dueAt: instant, startAt: null, pinnedStart: null, completedAt: instant, deletedAt: null },
        { id: 'start-history', dueAt: null, startAt: instant, pinnedStart: null, completedAt: null, deletedAt: instant },
        { id: 'pin-history', dueAt: null, startAt: null, pinnedStart: instant, completedAt: null, deletedAt: null },
      ]
      for (const value of cases) {
        const template = { anchorDate: rule.startDate, categoryId: 'work', title: value.id, notes: null, durationMinutes: 30,
          minChunkMinutes: null, priority: 'medium', deadlineType: 'soft', dueAt: null, startAt: null, pinnedStart: null,
          scheduleId: null, context: 'computer', projectId: null, attention: null }
        await client.query(`insert into task_recurrences (id, revision, rule, template, from_date)
          values ($1, $1, $2, $3, $4)`, [value.id, JSON.stringify(rule), JSON.stringify(template), rule.startDate])
        await client.query(`insert into tasks (id, category_id, title, duration_minutes, priority, deadline_type, due_at, start_at, pinned_start,
          completed_at, deleted_at, recurrence_series_id) values ($1, 'work', $1, 30, 'medium', 'soft', $2, $3, $4, $5, $6, $1)`,
        [value.id, value.dueAt, value.startAt, value.pinnedStart, value.completedAt, value.deletedAt])
      }
      await migrate()
      expect((await db.select().from(schema.taskRecurrences)).every((row) => !row.template.someday)).toBe(true)
      expect((await db.select().from(schema.tasks)).every((row) => !row.someday)).toBe(true)
    } finally {
      await client.close()
    }
  })

  it('backfills only real-category rows and templates with no due, start or pin', async () => {
    const { client, db, migrate } = await beforeMigration()
    try {
      const rule: RecurrenceRule = { frequency: 'day', interval: 1, timeZone: 'America/Los_Angeles', startDate: '2028-01-31' }
      const cases = [
        { id: 'empty', categoryId: 'work', dueAt: null, startAt: null, pinnedStart: null, expected: true },
        { id: 'start', categoryId: 'work', dueAt: null, startAt: '2028-01-31T18:00:00Z', pinnedStart: null, expected: false },
        { id: 'pin', categoryId: 'work', dueAt: null, startAt: null, pinnedStart: '2028-01-31T18:00:00Z', expected: false },
        { id: 'due', categoryId: 'work', dueAt: '2028-01-31T18:00:00Z', startAt: null, pinnedStart: null, expected: false },
        { id: 'inbox', categoryId: 'inbox', dueAt: null, startAt: null, pinnedStart: null, expected: false },
      ]
      for (const value of cases) {
        await client.query(`insert into tasks (id, category_id, title, duration_minutes, priority, deadline_type, due_at, start_at, pinned_start)
          values ($1, $2, $1, 30, 'medium', 'none', $3, $4, $5)`, [value.id, value.categoryId, value.dueAt, value.startAt, value.pinnedStart])
        const template = { anchorDate: rule.startDate, categoryId: value.categoryId, title: value.id, notes: null, durationMinutes: 30,
          minChunkMinutes: null, priority: 'medium', deadlineType: 'none', dueAt: value.dueAt, startAt: value.startAt, pinnedStart: value.pinnedStart,
          scheduleId: null, context: 'computer', projectId: null, attention: null }
        await client.query(`insert into task_recurrences (id, revision, rule, template, from_date) values ($1, $1, $2, $3, $4)`,
          [value.id, JSON.stringify(rule), JSON.stringify(template), rule.startDate])
      }
      await migrate()
      for (const row of await db.select().from(schema.tasks)) {
        expect(row.someday).toBe(cases.find((value) => value.id === row.id)!.expected)
      }
      for (const row of await db.select().from(schema.taskRecurrences)) {
        expect(row.template.someday).toBe(cases.find((value) => value.id === row.id)!.expected)
      }
    } finally {
      await client.close()
    }
  })

  it('preserves the sanitized production shape and existing Inbox count, including completed tasks and tombstones, and rolls all decisions through incremental sync', async () => {
    const { client, db, migrate } = await beforeMigration()
    try {
      await db.insert(schema.categories).values(fixture.categories.filter((category) => category.id !== 'inbox').map((category) => ({
        id: category.id, name: category.id, scheduleId: 'work', deletedAt: category.deletedAt === null ? null : new Date(category.deletedAt),
      })))
      for (const task of fixture.tasks) {
        await client.query(`insert into tasks (id, category_id, title, duration_minutes, priority, deadline_type, due_at, start_at, pinned_start, completed_at, deleted_at, updated_at)
          values ($1, $2, $1, 30, 'medium', $3, $4, $5, $6, $7, $8, $9)`,
        [task.id, task.categoryId, task.deadlineType, task.dueAt, task.startAt, task.pinnedStart, task.completedAt, task.deletedAt, task.updatedAt])
      }
      const before = (await client.query<Record<string, unknown>>('select * from tasks order by id')).rows
      const cursor = new Date().toISOString()
      await sleep(5)
      await migrate()
      const rows = await db.select().from(schema.tasks).orderBy(schema.tasks.id)
      expect(rows).toHaveLength(32)
      expect(rows.filter((task) => task.deletedAt === null)).toHaveLength(27)
      const open = rows.filter((task) => task.deletedAt === null && task.completedAt === null)
      expect(open).toHaveLength(12)
      expect(open.filter((task) => task.categoryId === 'inbox')).toHaveLength(1)
      expect(open.filter((task) => task.categoryId === 'inbox' || task.dueAt === null)).toHaveLength(2)
      expect(open.filter((task) => task.categoryId === 'inbox' || (task.dueAt === null && task.startAt === null && task.pinnedStart === null && !task.someday))).toHaveLength(1)
      expect(rows.filter((task) => task.someday)).toHaveLength(10)
      expect(rows.filter((task) => task.deletedAt === null && task.someday)).toHaveLength(8)
      expect(open.filter((task) => task.someday)).toHaveLength(1)
      for (const row of rows) {
        const original = fixture.tasks.find((task) => task.id === row.id)!
        expect(row.someday).toBe(original.categoryId !== 'inbox' && original.dueAt === null && original.startAt === null && original.pinnedStart === null)
        expect(row.updatedAt.getTime()).toBeGreaterThan(Date.parse(original.updatedAt))
        expect(row.updatedAt.getTime()).toBeGreaterThan(Date.parse(cursor))
      }
      const after = (await client.query<Record<string, unknown>>('select * from tasks order by id')).rows
      const originalFields = (row: Record<string, unknown>) => Object.fromEntries(Object.entries(row).filter(([key]) => key !== 'someday' && key !== 'updated_at'))
      expect(after.map(originalFields)).toEqual(before.map(originalFields))
      const app = createApp({ db, config, sync: new FakeSync(), reschedule: async () => ({ placements: [], unscheduled: [], late: [], optional: [], projectPlacements: [] }) })
      const response = await app.request(`/api/sync?since=${cursor}`, { headers: { authorization: `Bearer ${config.API_TOKEN}` } })
      expect(response.status).toBe(200)
      const delta = await response.json() as { tasks: { id: string; someday: boolean }[] }
      expect(delta.tasks).toHaveLength(32)
      expect(delta.tasks.map((task) => [task.id, task.someday]).sort()).toEqual(rows.map((task) => [task.id, task.someday]).sort())
      const created = await upsertTask(db, 'new-after-migration', { categoryId: 'work', title: 'New capture', durationMinutes: 30, priority: 'medium', deadlineType: 'none' })
      expect(created.someday).toBe(false)
      const [databaseDefault] = await db.insert(schema.tasks).values({ id: 'database-default', categoryId: 'work', title: 'Database default', durationMinutes: 30, priority: 'medium', deadlineType: 'none' }).returning()
      expect(databaseDefault?.someday).toBe(false)
    } finally {
      await client.close()
    }
  })

  it('backfills recurrence JSON templates and future occurrences, including stopped series, without changing due dates or recurrence rules', async () => {
    const { client, db, migrate } = await beforeMigration()
    try {
      const rule: RecurrenceRule = { frequency: 'month', interval: 1, timeZone: 'America/Los_Angeles', startDate: '2028-01-31' }
      const old = new Date('2026-01-01T00:00:00Z')
      const templates = [
        { id: 'undated', categoryId: 'work', dueAt: null, expected: true },
        { id: 'inbox', categoryId: 'inbox', dueAt: null, expected: false },
        { id: 'dated', categoryId: 'work', dueAt: '2028-02-01T07:59:59.999Z', expected: false },
        { id: 'stopped', categoryId: 'work', dueAt: null, expected: true },
      ] as const
      for (const value of templates) {
        const template = {
          anchorDate: rule.startDate, categoryId: value.categoryId, title: value.id, notes: null, durationMinutes: 30,
          minChunkMinutes: null, priority: 'medium', deadlineType: 'soft', dueAt: value.dueAt, startAt: null,
          scheduleId: null, context: 'computer', projectId: null, attention: null, pinnedStart: null,
        }
        await client.query(`insert into task_recurrences (id, revision, rule, template, from_date, updated_at, deleted_at)
          values ($1, $1, $2, $3, $4, $5, $6)`,
        [value.id, JSON.stringify(rule), JSON.stringify(template), rule.startDate, old.toISOString(), value.id === 'stopped' ? old.toISOString() : null])
      }
      await migrate()
      const series = await db.select().from(schema.taskRecurrences)
      for (const row of series) {
        const value = templates.find((item) => item.id === row.id)!
        expect(row.template).toMatchObject({ categoryId: value.categoryId, dueAt: value.dueAt, someday: value.expected })
        expect(row.rule).toEqual(rule)
        expect(row.revision).toBe(row.id)
        expect(row.updatedAt.getTime()).toBeGreaterThan(old.getTime())
      }
      await db.transaction((tx) => materializeRecurringTasks(tx, new Date('2028-01-31T16:00:00Z'), 100))
      const occurrences = await db.select().from(schema.tasks)
      expect(occurrences).toHaveLength(12)
      for (const task of occurrences) {
        expect(task.recurrenceSeriesId).not.toBe('stopped')
        expect(task.someday).toBe(templates.find((item) => item.id === task.recurrenceSeriesId)!.expected)
        expect(task.dueAt === null).toBe(task.someday)
        if (task.someday) expect(task.deadlineType).toBe('none')
        expect(task.recurrence).toEqual(rule)
      }
      expect(occurrences.filter((task) => task.recurrenceDate === '2028-02-29' && !task.someday).map((task) => task.dueAt?.toISOString())).toEqual(Array(2).fill('2028-03-01T07:59:59.999Z'))
    } finally {
      await client.close()
    }
  })
})
