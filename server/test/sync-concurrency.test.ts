import { randomUUID } from 'node:crypto'
import { setTimeout as sleep } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { eq, sql } from 'drizzle-orm'
import { drizzle } from 'drizzle-orm/postgres-js'
import { migrate } from 'drizzle-orm/postgres-js/migrator'
import postgres from 'postgres'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp } from '../src/app.js'
import type { Db } from '../src/db/client.js'
import * as schema from '../src/db/schema.js'
import { events } from '../src/db/schema.js'
import { syncCursor, writeTimestamp } from '../src/db/sync-clock.js'
import { setEventBlocksDay } from '../src/events.js'
import { learnAccountProfiles, refreshAllDayJudgments, repairLegacyJudgmentCursors } from '../src/google/all-day-state.js'
import { seed } from '../src/seed.js'
import { FakeSync, testConfig } from './fixtures.js'

const url = process.env.TEST_DATABASE_URL

describe.skipIf(url === undefined)('concurrent Postgres sync cursors', () => {
  let admin: ReturnType<typeof postgres>
  let client: ReturnType<typeof postgres>
  let database: string
  let db: Db
  const queries: string[] = []

  beforeEach(async () => {
    if (url === undefined) throw new Error('TEST_DATABASE_URL is required')
    const target = new URL(url)
    if (!['localhost', '127.0.0.1', 'postgres'].includes(target.hostname)) throw new Error('Tests require an isolated local database')
    admin = postgres(url, { prepare: false, max: 2 })
    database = `florida_sync_${randomUUID().replaceAll('-', '')}`
    await admin.unsafe(`create database "${database}"`)
    target.pathname = '/' + database
    client = postgres(target.toString(), { prepare: false, max: 5 })
    db = drizzle(client, { schema, logger: { logQuery: (query) => queries.push(query) } })
    await migrate(db as ReturnType<typeof drizzle<typeof schema>>, { migrationsFolder: fileURLToPath(new URL('../drizzle', import.meta.url)) })
    await seed(db)
    await db.insert(schema.googleAccounts).values({ id: 'owner', email: 'owner@example.com', label: 'personal', refreshTokenEnc: 'test', displayName: 'Test Owner' })
    await db.insert(schema.calendars).values({ id: 'calendar', accountId: 'owner', googleId: 'owner@example.com', summary: 'Personal', accessRole: 'owner' })
  })

  afterEach(async () => {
    vi.restoreAllMocks()
    if (client !== undefined) await client.end()
    if (admin !== undefined) {
      if (database !== undefined) await admin.unsafe(`drop database if exists "${database}" with (force)`)
      await admin.end()
    }
  })

  async function pull(since?: string) {
    const app = createApp({ db, config: testConfig, sync: new FakeSync(), reschedule: async () => ({ placements: [], unscheduled: [], late: [] }) })
    const response = await app.request('/api/sync' + (since === undefined ? '' : '?since=' + encodeURIComponent(since)), {
      headers: { authorization: 'Bearer ' + testConfig.API_TOKEN },
    })
    expect(response.status).toBe(200)
    return await response.json() as { cursor: string; events: { id: string; blocksDay: boolean | null; autoBlocksDay: boolean | null; blockingReason: string | null; updatedAt: string }[]; categories: { id: string; updatedAt: string }[] }
  }

  async function holiday(id = 'holiday') {
    await db.insert(events).values({
      id, calendarId: 'calendar', googleId: id, summary: 'Holiday',
      description: 'Today is a paid company holiday. Enjoy your time off!', status: 'confirmed',
      allDay: true, startAt: new Date('2026-11-26T00:00:00Z'), endAt: new Date('2026-11-27T00:00:00Z'),
      updatedAt: new Date('2026-11-01T00:00:00Z'),
    })
  }

  async function waitForLock(event: string, queryPrefix = '') {
    for (let i = 0; i < 200; i++) {
      const [row] = await client<{ blocked: boolean }[]>`select exists(select 1 from pg_stat_activity where datname=current_database() and wait_event=${event} and query like ${queryPrefix + '%'}) as blocked`
      if (row?.blocked === true) return
      await sleep(10)
    }
    throw new Error('Writer did not reach its expected lock')
  }

  async function heldWrite(write: () => Promise<void>, check: () => Promise<void>, table = 'events', operation = 'update') {
    if (!['events', 'routine_blocks'].includes(table) || !['update', 'insert'].includes(operation)) throw new Error('Unexpected test trigger')
    await db.execute(sql.raw(`create function pause_event_write() returns trigger language plpgsql as $$
      begin perform pg_advisory_xact_lock(557901); return new; end $$;
      create trigger pause_event_write before ${operation} on ${table} for each row execute function pause_event_write()`))
    let ready!: () => void
    let release!: () => void
    const acquired = new Promise<void>((resolve) => { ready = resolve })
    const gate = new Promise<void>((resolve) => { release = resolve })
    const blocker = client.begin(async (connection) => {
      await connection`select pg_advisory_xact_lock(557901)`
      ready()
      await gate
    })
    await acquired
    const writing = write()
    try {
      await waitForLock('advisory', `${operation === 'insert' ? 'insert into' : 'update'} "${table}"`)
      await sleep(20)
      await check()
    } finally {
      release()
      await blocker
      await writing
    }
  }

  it('delivers judged rows after a pull made while the backfill is uncommitted', async () => {
    await holiday()
    const before = await pull()
    let during!: Awaited<ReturnType<typeof pull>>
    await heldWrite(() => refreshAllDayJudgments(db), async () => {
      during = await pull(before.cursor)
      expect(during.events).toEqual([])
      expect((await db.select().from(events))[0]?.autoBlocksDay).toBeNull()
    })
    const after = await pull(during.cursor)
    expect(after.events).toMatchObject([{ id: 'holiday', autoBlocksDay: true, blockingReason: 'Company holiday' }])
    expect(new Date(after.events[0]!.updatedAt).getTime()).toBeGreaterThan(new Date(during.cursor).getTime())
  })

  it('anchors the cursor before a writer that begins after the activity snapshot', async () => {
    await holiday()
    const reader = postgres(client.options, { max: 1, prepare: false })
    let ready!: (pid: number) => void
    let release!: () => void
    const acquired = new Promise<number>((resolve) => { ready = resolve })
    const gate = new Promise<void>((resolve) => { release = resolve })
    const blocker = client.begin(async (connection) => {
      const [row] = await connection<{ pid: number }[]>`select pg_backend_pid() as pid, pg_advisory_xact_lock(557902)`
      ready(row!.pid)
      await gate
    })
    const holder = await acquired
    let cursor!: Date
    let unfenced!: Date
    try {
      await db.execute(sql.raw(`create schema clock_test;
        create function clock_test.activity_snapshot() returns setof pg_catalog.pg_stat_activity language plpgsql as $$
        declare snapshot jsonb;
        begin
          select jsonb_agg(to_jsonb(activity)) into snapshot from pg_catalog.pg_stat_activity activity where pid <> ${holder};
          perform pg_advisory_xact_lock(557902);
          return query select * from jsonb_populate_recordset(null::pg_catalog.pg_stat_activity, snapshot);
        end $$;
        create view clock_test.pg_stat_activity as select * from clock_test.activity_snapshot()`))
      await reader`set search_path to clock_test, pg_catalog, public`
      const reading = syncCursor(drizzle(reader, { schema }))
      await waitForLock('advisory', 'select to_char')
      await heldWrite(() => refreshAllDayJudgments(db), async () => {
        release()
        await blocker
        cursor = await reading
        const [clock] = await client<{ cursor: string }[]>`select clock_timestamp()::text as cursor`
        unfenced = new Date(clock!.cursor)
        expect((await db.select().from(events))[0]?.autoBlocksDay).toBeNull()
      })
      expect((await pull(unfenced.toISOString())).events).toEqual([])
      expect((await pull(cursor.toISOString())).events).toMatchObject([{ id: 'holiday', autoBlocksDay: true }])
    } finally {
      release()
      await blocker
      await reader.end()
    }
  })

  it('repairs the v14 cohort for later cursors exactly once without changing overrides', async () => {
    await holiday()
    await db.update(events).set({ autoBlocksDay: true, blockingReason: 'Company holiday', blocksDay: false,
      updatedAt: new Date('2026-11-13T13:32:03.087Z') }).where(eq(events.id, 'holiday'))
    for (const id of ['newer', 'timed', 'deleted', 'unjudged']) await holiday(id)
    await db.update(events).set({ autoBlocksDay: true, updatedAt: new Date('2026-11-13T13:32:03.088Z') }).where(eq(events.id, 'newer'))
    await db.update(events).set({ autoBlocksDay: true, allDay: false }).where(eq(events.id, 'timed'))
    await db.update(events).set({ autoBlocksDay: true, deletedAt: new Date('2026-11-02T00:00:00Z') }).where(eq(events.id, 'deleted'))
    const excluded = (await db.select().from(events)).filter((row) => row.id !== 'holiday')
    const late = await pull()
    expect((await pull(late.cursor)).events).toEqual([])
    let during!: Awaited<ReturnType<typeof pull>>
    await heldWrite(() => repairLegacyJudgmentCursors(db), async () => {
      during = await pull(late.cursor)
      expect(during.events).toEqual([])
    })
    expect((await pull(during.cursor)).events).toMatchObject([{ id: 'holiday', blocksDay: false, autoBlocksDay: true, blockingReason: 'Company holiday' }])
    const first = await db.select().from(events)
    expect(first.filter((row) => row.id !== 'holiday')).toEqual(excluded)
    await repairLegacyJudgmentCursors(db)
    expect(await db.select().from(events)).toEqual(first)
  })

  it('uses one bulk judgment update and no writes for an unchanged hourly refresh', async () => {
    await db.insert(events).values(Array.from({ length: 2076 }, (_, i) => ({
      id: 'holiday-' + i, calendarId: 'calendar', googleId: 'holiday-' + i, summary: 'Holiday',
      description: 'Today is a paid company holiday. Enjoy your time off!', status: 'confirmed', allDay: true,
      startAt: new Date('2026-11-26T00:00:00Z'), endAt: new Date('2026-11-27T00:00:00Z'),
    })))
    queries.length = 0
    await refreshAllDayJudgments(db)
    expect(queries.filter((query) => query.startsWith('update "events"'))).toHaveLength(1)
    expect((await db.select().from(events)).every((event) => event.autoBlocksDay === true)).toBe(true)
    queries.length = 0
    await refreshAllDayJudgments(db)
    expect(queries.filter((query) => query.startsWith('update "events"'))).toEqual([])
  })

  it('stamps late release-seed writes after delayed earlier statements', async () => {
    await db.execute(sql.raw(`create function delay_settings_seed() returns trigger language plpgsql as $$
      begin perform pg_sleep(0.05); return new; end $$;
      create trigger delay_settings_seed before insert on settings for each row execute function delay_settings_seed()`))
    const before = await pull()
    let during!: Awaited<ReturnType<typeof pull>>
    await heldWrite(() => seed(db), async () => {
      during = await pull(before.cursor)
    }, 'routine_blocks', 'insert')
    expect((await pull(during.cursor)).categories.map((row) => row.id)).toContain('inbox')
  })

  it('compares sub-millisecond stored versions without losing the judgment update', async () => {
    await holiday()
    await db.execute(sql`update ${events} set updated_at = '2026-11-01T00:00:00.123456Z'::timestamptz`)
    await refreshAllDayJudgments(db)
    expect((await db.select().from(events))[0]).toMatchObject({ autoBlocksDay: true, blockingReason: 'Company holiday' })
  })

  it('retries a bulk refresh around a concurrent manual override', async () => {
    await holiday()
    const transaction = vi.spyOn(db, 'transaction')
    let refresh!: Promise<void>
    await heldWrite(async () => { await setEventBlocksDay(db, 'holiday', false) }, async () => {
      refresh = refreshAllDayJudgments(db)
      await waitForLock('transactionid')
    })
    await refresh
    expect(transaction.mock.calls.filter((call) => call[1]?.isolationLevel === 'repeatable read')).toHaveLength(2)
    expect((await db.select().from(events))[0]).toMatchObject({ blocksDay: false, autoBlocksDay: true, blockingReason: 'Company holiday' })
  })

  it('retries around profile learning and keeps the newly identified own time off', async () => {
    await holiday()
    await db.update(schema.googleAccounts).set({ displayName: null }).where(eq(schema.googleAccounts.id, 'owner'))
    await db.update(events).set({ summary: 'Test Owner - OOO', description: null })
    const transaction = vi.spyOn(db, 'transaction')
    let refresh!: Promise<void>
    await heldWrite(async () => {
      await db.transaction(async (tx) => {
        await learnAccountProfiles(tx, [{ organizer: { email: 'owner@example.com', displayName: 'Test Owner' } }], new Date())
        await tx.update(events).set({ autoBlocksDay: true, blockingReason: 'Your time off', updatedAt: writeTimestamp })
      })
    }, async () => {
      refresh = refreshAllDayJudgments(db)
      await waitForLock('transactionid')
    })
    await refresh
    expect(transaction.mock.calls.filter((call) => call[1]?.isolationLevel === 'repeatable read')).toHaveLength(2)
    expect((await db.select().from(events))[0]).toMatchObject({ autoBlocksDay: true, blockingReason: 'Your time off' })
  })
})
