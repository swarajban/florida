import { readFile } from 'node:fs/promises'
import { PGlite } from '@electric-sql/pglite'
import { eq } from 'drizzle-orm'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp } from '../src/app.js'
import { explainFacts } from '../src/briefs.js'
import type { Db } from '../src/db/client.js'
import { calendars, events, googleAccounts, tasks } from '../src/db/schema.js'
import type { CalendarRow } from '../src/db/schema.js'
import { learnAccountProfiles, refreshAllDayJudgments } from '../src/google/all-day-state.js'
import { GoogleSync } from '../src/google/sync.js'
import { runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'
import { FakeSync, testConfig } from './fixtures.js'

const now = new Date('2026-11-09T16:00:00Z')
const allDay = { status: 'confirmed', allDay: true, startAt: new Date('2026-11-09T00:00:00Z'), endAt: new Date('2026-11-10T00:00:00Z'), updatedAt: new Date('2026-11-01T00:00:00Z') }

describe('automatic all-day migration', () => {
  it('leaves judgments and profile names nullable without changing calendar choices, sync tokens or timestamps', async () => {
    const client = new PGlite()
    try {
      await client.exec(`CREATE TABLE events (id text, blocks_day boolean);
        INSERT INTO events VALUES ('manual', false), ('automatic', null);
        CREATE TABLE google_accounts (id text);
        INSERT INTO google_accounts VALUES ('personal'), ('work');
        CREATE TABLE tasks (id text, updated_at timestamptz);
        INSERT INTO tasks VALUES ('linked', '2026-01-01');
        CREATE TABLE calendars (id text, google_id text, selected boolean, blocks_scheduling boolean, sync_token text, updated_at timestamptz);
        INSERT INTO calendars VALUES
          ('personal-us', 'en.usa#holiday@group.v.calendar.google.com', false, false, 'old-personal', '2026-01-01'),
          ('work-us', 'en.usa#holiday@group.v.calendar.google.com', false, false, 'old-work', '2026-01-01'),
          ('opted-us', 'en.usa#holiday@group.v.calendar.google.com', false, true, 'user-token', '2026-01-01'),
          ('gusto', 'gusto-feed', true, true, 'gusto-token', '2026-01-01'),
          ('other-holidays', 'en.uk#holiday@group.v.calendar.google.com', false, false, 'uk-token', '2026-01-01'),
          ('coworker', 'alex@example.com', false, false, 'coworker-token', '2026-01-01');`)
      const calendarRows = (await client.query('SELECT * FROM calendars ORDER BY id')).rows
      await client.exec(await readFile(new URL('../drizzle/0009_bored_annihilus.sql', import.meta.url), 'utf8'))
      await client.query('UPDATE tasks SET source = $1::jsonb', [JSON.stringify({
        url: 'https://github.com/acme/app/issues/1', title: 'acme/app#1', kind: 'github',
      })])
      const taskRows = (await client.query('SELECT * FROM tasks')).rows
      await client.exec(await readFile(new URL('../drizzle/0010_tired_vampiro.sql', import.meta.url), 'utf8'))
      expect((await client.query('SELECT blocks_day, auto_blocks_day, blocking_reason FROM events ORDER BY id')).rows).toEqual([
        { blocks_day: null, auto_blocks_day: null, blocking_reason: null },
        { blocks_day: false, auto_blocks_day: null, blocking_reason: null },
      ])
      expect((await client.query('SELECT display_name FROM google_accounts')).rows).toEqual([{ display_name: null }, { display_name: null }])
      expect((await client.query('SELECT * FROM calendars ORDER BY id')).rows).toEqual(calendarRows)
      expect((await client.query('SELECT * FROM tasks')).rows).toEqual(taskRows)
    } finally {
      await client.close()
    }
  })
})

describe('automatic all-day persistence', () => {
  let db: Db
  let close: () => Promise<void>
  let work: CalendarRow
  let gusto: CalendarRow

  beforeAll(async () => {
    ;({ db, close } = await createTestDb())
    await seed(db)
  })
  afterAll(() => close())
  beforeEach(async () => {
    await db.delete(events)
    await db.delete(calendars)
    await db.delete(googleAccounts)
    await db.delete(tasks)
    await db.insert(googleAccounts).values([
      { id: 'personal', email: 'jordan@example.com', label: 'personal', refreshTokenEnc: 'secret', accessToken: 'token', accessTokenExpiresAt: new Date(Date.now() + 3_600_000) },
      { id: 'work', email: 'jordan@work.example', label: 'work', refreshTokenEnc: 'secret', accessToken: 'token', accessTokenExpiresAt: new Date(Date.now() + 3_600_000) },
    ])
    const rows = await db.insert(calendars).values([
      { id: 'work-cal', accountId: 'work', googleId: 'jordan@work.example', summary: 'Work', accessRole: 'owner' },
      { id: 'gusto-cal', accountId: 'work', googleId: 'gusto-feed', summary: 'Gusto: Example reminders', accessRole: 'reader' },
    ]).returning()
    work = rows.find((row) => row.id === 'work-cal')!
    gusto = rows.find((row) => row.id === 'gusto-cal')!
  })
  afterEach(() => vi.unstubAllGlobals())

  it('does not enroll other people or new holiday feeds when an account connects', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => Response.json({ items: [
      { id: 'jordan@work.example', primary: true, accessRole: 'owner', summary: 'Not profile metadata' },
      { id: 'alex@work.example', accessRole: 'owner' },
      { id: 'en.usa#holiday@group.v.calendar.google.com', accessRole: 'reader' },
      { id: 'family@group.calendar.google.com', accessRole: 'writer' },
      { id: 'other@group.calendar.google.com', accessRole: 'reader' },
    ] })))
    const sync = new GoogleSync(db, testConfig)
    await sync.connectAccount('work', { accessToken: 'new-token', refreshToken: 'refresh', expiresAt: new Date(Date.now() + 3_600_000) })
    const rows = await db.select().from(calendars)
    expect(rows.find((row) => row.googleId === 'alex@work.example')).toMatchObject({ selected: false, blocksScheduling: false })
    expect(rows.find((row) => row.googleId === 'en.usa#holiday@group.v.calendar.google.com')).toMatchObject({ selected: false, blocksScheduling: false })
    expect(rows.find((row) => row.googleId === 'family@group.calendar.google.com')).toMatchObject({ selected: true, blocksScheduling: true })
    expect(rows.find((row) => row.googleId === 'other@group.calendar.google.com')).toMatchObject({ selected: false, blocksScheduling: false })
    expect(rows.find((row) => row.id === gusto.id)).toMatchObject({ selected: true, blocksScheduling: true })
    expect((await db.select().from(googleAccounts).where(eq(googleAccounts.id, 'work')))[0]?.displayName).toBeNull()
  })

  it('syncs and protects public holidays only after the calendar is explicitly opted into blocking', async () => {
    const [holiday] = await db.insert(calendars).values({
      id: 'us-holidays', accountId: 'work', googleId: 'en.usa#holiday@group.v.calendar.google.com',
      summary: 'Holidays in United States', accessRole: 'reader', selected: false, blocksScheduling: false,
    }).returning()
    await db.insert(events).values({ ...allDay, id: 'public', googleId: 'public', calendarId: holiday!.id,
      summary: 'Public holiday', description: 'Public holiday' })
    await db.insert(tasks).values({ id: 'deadline', categoryId: 'inbox', title: 'Report', durationMinutes: 60, priority: 'medium',
      deadlineType: 'hard', dueAt: new Date('2026-11-10T00:00:00Z') })
    await refreshAllDayJudgments(db, now)
    expect((await db.select().from(events).where(eq(events.id, 'public')))[0])
      .toMatchObject({ autoBlocksDay: true, blockingReason: 'Public holiday' })
    expect((await runScheduling(db, testConfig, now)).placements.some((row) => row.taskId === 'deadline')).toBe(true)

    const sync = new GoogleSync(db, testConfig)
    const calendarSync = vi.spyOn(sync, 'syncCalendar').mockResolvedValue()
    const watch = vi.spyOn(sync, 'ensureWatch').mockResolvedValue()
    const [account] = await db.select().from(googleAccounts).where(eq(googleAccounts.id, 'work'))
    try {
      await sync.syncAccount(account!)
      expect(calendarSync.mock.calls.some(([calendar]) => calendar.id === holiday!.id)).toBe(false)
      expect(watch.mock.calls.some(([calendar]) => calendar.id === holiday!.id)).toBe(false)
      await db.update(calendars).set({ blocksScheduling: true }).where(eq(calendars.id, holiday!.id))
      await sync.syncAccount(account!)
      expect(calendarSync.mock.calls.some(([calendar]) => calendar.id === holiday!.id)).toBe(true)
      expect(watch.mock.calls.some(([calendar]) => calendar.id === holiday!.id)).toBe(true)
      expect((await runScheduling(db, testConfig, now)).placements.some((row) => row.taskId === 'deadline')).toBe(false)
      expect((await db.select().from(calendars).where(eq(calendars.id, holiday!.id)))[0])
        .toMatchObject({ selected: false, blocksScheduling: true })
    } finally {
      calendarSync.mockRestore()
      watch.mockRestore()
    }
  })

  it('learns only matching connected emails from Google organizer/attendee metadata and never overwrites a known name', async () => {
    const result = await learnAccountProfiles(db, [{
      organizer: { email: 'JORDAN@EXAMPLE.COM', displayName: 'Jordan Rivera' },
      attendees: [
        { email: 'jordan@work.example', displayName: 'Jordan R. Rivera' },
        { email: 'stranger@example.com', displayName: 'Not the account owner' },
      ],
    }], now)
    expect(result.learned).toBe(true)
    expect(result.profiles).toEqual(expect.arrayContaining([
      { id: 'personal', email: 'jordan@example.com', displayName: 'Jordan Rivera' },
      { id: 'work', email: 'jordan@work.example', displayName: 'Jordan R. Rivera' },
    ]))
    expect((await learnAccountProfiles(db, [{ organizer: { email: 'jordan@example.com', displayName: 'Replacement' } }], new Date(now.getTime() + 1))).learned).toBe(false)
    const [personal] = await db.select().from(googleAccounts).where(eq(googleAccounts.id, 'personal'))
    expect(personal).toMatchObject({ displayName: 'Jordan Rivera', updatedAt: now })
  })

  it('collects names from stored timed metadata before backfilling Gusto and preserves manual overrides and tombstones', async () => {
    await db.insert(events).values([
      { ...allDay, id: 'own', googleId: 'own', calendarId: gusto.id, summary: 'Pending Jordan R - OOO', blocksDay: false },
      { ...allDay, id: 'other', googleId: 'other', calendarId: gusto.id, summary: 'Pending Alex M - OOO', blocksDay: true },
      { ...allDay, id: 'legacy', googleId: 'legacy', calendarId: work.id, summary: 'Away', eventType: 'outOfOffice' },
      { ...allDay, id: 'dead', googleId: 'dead', calendarId: work.id, summary: 'Vacation', deletedAt: now },
      { ...allDay, id: 'metadata', googleId: 'metadata', calendarId: work.id, allDay: false,
        organizer: { email: 'jordan@example.com', displayName: 'Jordan Rivera', self: false },
        attendees: [{ email: 'jordan@work.example', displayName: null, responseStatus: 'accepted', organizer: false, self: true, optional: false }] },
    ])
    await refreshAllDayJudgments(db, now)
    const rows = await db.select().from(events)
    expect(rows.find((row) => row.id === 'own')).toMatchObject({ autoBlocksDay: true, blockingReason: 'Your time off', blocksDay: false })
    expect(rows.find((row) => row.id === 'other')).toMatchObject({ autoBlocksDay: false, blockingReason: 'Someone else’s time off', blocksDay: true })
    expect(rows.find((row) => row.id === 'legacy')).toMatchObject({ autoBlocksDay: true, blockingReason: 'Your time off', blocksDay: null })
    expect(rows.find((row) => row.id === 'dead')).toMatchObject({ autoBlocksDay: null, blockingReason: null })
    expect(rows.find((row) => row.id === 'metadata')).toMatchObject({ autoBlocksDay: null, blockingReason: null })
    const accounts = await db.select().from(googleAccounts)
    expect(accounts.find((row) => row.id === 'personal')?.displayName).toBe('Jordan Rivera')
    expect(accounts.find((row) => row.id === 'work')?.displayName).toBeNull()
    await refreshAllDayJudgments(db, new Date(now.getTime() + 1000))
    expect((await db.select().from(events).where(eq(events.id, 'own')))[0]?.updatedAt).toEqual(now)
  })

  it('reconciles a cached nameless profile when another writer already learned the name', async () => {
    const cached = [{ id: 'personal', email: 'jordan@example.com', displayName: null }]
    await learnAccountProfiles(db, [{ organizer: { email: 'jordan@example.com', displayName: 'Jordan Rivera' } }], now)
    const result = await learnAccountProfiles(db, [{ organizer: { email: 'jordan@example.com', displayName: 'Replacement' } }], now, cached)
    expect(result.profiles[0]?.displayName).toBe('Jordan Rivera')
    expect(result.learned).toBe(true)
  })

  it('skips event metadata entirely when every connected account has a name', async () => {
    await db.update(googleAccounts).set({ displayName: 'Jordan Rivera' })
    await db.insert(events).values({ ...allDay, id: 'holiday', googleId: 'holiday', calendarId: gusto.id, summary: 'Company holiday' })
    const selections: unknown[] = []
    const transaction = db.transaction.bind(db)
    const spy = vi.spyOn(db, 'transaction').mockImplementation((callback, config) => transaction(async (tx) => {
      const select = vi.spyOn(tx, 'select')
      try {
        return await callback(tx)
      } finally {
        selections.push(...select.mock.calls.map((call) => call[0]))
        select.mockRestore()
      }
    }, config))
    try {
      await refreshAllDayJudgments(db, now)
      expect(selections).toHaveLength(2)
      expect(selections).not.toContainEqual({ organizer: events.organizer, attendees: events.attendees })
      expect((await db.select().from(events).where(eq(events.id, 'holiday')))[0])
        .toMatchObject({ autoBlocksDay: true, blockingReason: 'Company holiday' })
    } finally {
      spy.mockRestore()
    }
  })

  it('learns unknown accounts from matching named metadata without replacing known names', async () => {
    await db.update(googleAccounts).set({ displayName: 'Jordan Rivera' }).where(eq(googleAccounts.id, 'personal'))
    await db.insert(events).values([
      { ...allDay, id: 'metadata', googleId: 'metadata', calendarId: work.id, allDay: false,
        organizer: { email: 'jordan@example.com', displayName: 'Replacement', self: false },
        attendees: [{ email: 'JORDAN@WORK.EXAMPLE', displayName: 'Jordan R. Rivera', responseStatus: 'accepted', organizer: false, self: true, optional: false }] },
      { ...allDay, id: 'other', googleId: 'other', calendarId: work.id, allDay: false,
        organizer: { email: 'stranger@example.com', displayName: 'Other Person', self: false } },
      { ...allDay, id: 'blank', googleId: 'blank', calendarId: work.id, allDay: false,
        organizer: { email: 'jordan@work.example', displayName: '  ', self: true } },
    ])
    await refreshAllDayJudgments(db, now)
    expect(await db.select({ id: googleAccounts.id, displayName: googleAccounts.displayName }).from(googleAccounts))
      .toEqual(expect.arrayContaining([
        { id: 'personal', displayName: 'Jordan Rivera' },
        { id: 'work', displayName: 'Jordan R. Rivera' },
      ]))
  })

  it('uses consistent refresh snapshots, retries serialization conflicts, and never moves event timestamps backward', async () => {
    const future = new Date(now.getTime() + 60_000)
    await db.insert(events).values({ ...allDay, id: 'holiday', googleId: 'holiday', calendarId: gusto.id,
      summary: 'Company holiday', updatedAt: future })
    const transaction = vi.spyOn(db, 'transaction').mockRejectedValueOnce(Object.assign(new Error('concurrent update'), { code: '40001' }))
    try {
      await refreshAllDayJudgments(db, now)
      expect(transaction).toHaveBeenCalledTimes(2)
      expect(transaction.mock.calls.every((call) => call[1]?.isolationLevel === 'repeatable read')).toBe(true)
      expect((await db.select().from(events).where(eq(events.id, 'holiday')))[0])
        .toMatchObject({ autoBlocksDay: true, blockingReason: 'Company holiday', updatedAt: new Date(future.getTime() + 1) })
    } finally {
      transaction.mockRestore()
    }
  })

  it('bounds conflict retries and does not retry unrelated database errors', async () => {
    const conflict = new Error('query failed', { cause: { code: '40001' } })
    const transaction = vi.spyOn(db, 'transaction').mockRejectedValue(conflict)
    try {
      await expect(refreshAllDayJudgments(db, now)).rejects.toBe(conflict)
      expect(transaction).toHaveBeenCalledTimes(3)
      transaction.mockClear()
      const failure = new Error('database unavailable')
      transaction.mockRejectedValue(failure)
      await expect(refreshAllDayJudgments(db, now)).rejects.toBe(failure)
      expect(transaction).toHaveBeenCalledTimes(1)
    } finally {
      transaction.mockRestore()
    }
  })

  it('reconciles profiles learned by a concurrent calendar before finishing a delayed Gusto sync', async () => {
    await db.insert(events).values({ ...allDay, id: 'held', googleId: 'g-own', calendarId: gusto.id, summary: 'Before', blocksDay: false })
    let releaseGusto!: () => void
    let startedGusto!: () => void
    const gate = new Promise<void>((resolve) => { releaseGusto = resolve })
    const started = new Promise<void>((resolve) => { startedGusto = resolve })
    vi.stubGlobal('fetch', vi.fn(async (url: string | URL) => {
      if (String(url).includes('/gusto-feed/')) {
        startedGusto()
        await gate
        return Response.json({ items: [{ id: 'g-own', summary: 'Jordan R - OOO',
          start: { date: '2026-11-09' }, end: { date: '2026-11-10' } }], nextSyncToken: 'gusto-after' })
      }
      return Response.json({ items: [{ id: 'g-name', summary: 'Metadata only',
        start: { dateTime: '2026-11-09T10:00:00Z' }, end: { dateTime: '2026-11-09T11:00:00Z' },
        organizer: { email: 'jordan@example.com', displayName: 'Jordan Rivera' } }], nextSyncToken: 'work-after' })
    }))
    const sync = new GoogleSync(db, testConfig)
    const delayed = sync.syncCalendar(gusto)
    await started
    try {
      await sync.syncCalendar(work)
    } finally {
      releaseGusto()
    }
    await delayed
    expect((await db.select().from(events).where(eq(events.id, 'held')))[0])
      .toMatchObject({ autoBlocksDay: true, blockingReason: 'Your time off', blocksDay: false })
  })

  it('rejudges Google changes and earlier pages after discovering names, without changing the override', async () => {
    await db.insert(events).values({ ...allDay, id: 'held', googleId: 'g-own', calendarId: gusto.id, summary: 'Before', blocksDay: false })
    const pages = [
      { items: [{ id: 'g-own', summary: 'Jordan R - OOO', start: { date: '2026-11-09' }, end: { date: '2026-11-10' } }], nextPageToken: 'next' },
      { items: [{ id: 'g-name', summary: 'Metadata only', start: { dateTime: '2026-11-09T10:00:00Z' }, end: { dateTime: '2026-11-09T11:00:00Z' },
        organizer: { email: 'jordan@example.com', displayName: 'Jordan Rivera' } }], nextSyncToken: 'after' },
    ]
    const fetch = vi.fn(async () => Response.json(pages.shift()))
    vi.stubGlobal('fetch', fetch)
    const sync = new GoogleSync(db, testConfig)
    await sync.syncCalendar(gusto)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect((await db.select().from(events).where(eq(events.id, 'held')))[0])
      .toMatchObject({ autoBlocksDay: true, blockingReason: 'Your time off', blocksDay: false })
    vi.stubGlobal('fetch', vi.fn(async () => Response.json({ items: [{ id: 'g-own', summary: 'Estimated exempt only payday',
      start: { date: '2026-11-09' }, end: { date: '2026-11-10' } }], nextSyncToken: 'next-after' })))
    await sync.syncCalendar({ ...gusto, syncToken: 'after' })
    expect((await db.select().from(events).where(eq(events.id, 'held')))[0])
      .toMatchObject({ autoBlocksDay: false, blockingReason: 'Gusto reminder', blocksDay: false })
  })

  it('persists create/update judgments and exposes them and profile names through GET/sync; PATCH never calls Google', async () => {
    const fake = new FakeSync()
    const create = fake.createEvent.bind(fake)
    vi.spyOn(fake, 'createEvent').mockImplementation(async (calendar, input) => {
      const result = await create(calendar, input)
      result.organizer = { email: 'jordan@example.com', displayName: 'Jordan Rivera' }
      fake.googleEvents.set(result.id, result)
      return result
    })
    const app = createApp({ db, config: testConfig, sync: fake, reschedule: () => runScheduling(db, testConfig, now) })
    const request = (path: string, method = 'GET', body?: unknown) => app.request(path, {
      method, headers: { authorization: `Bearer ${testConfig.API_TOKEN}`, 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
    const input = { calendarId: work.id, summary: 'Trip to Paris', allDay: true,
      startAt: allDay.startAt.toISOString(), endAt: allDay.endAt.toISOString() }
    const created = await request('/api/events/new-trip', 'PUT', input)
    expect(created.status).toBe(200)
    expect(await created.json()).toMatchObject({ event: { blocksDay: null, autoBlocksDay: true, blockingReason: 'Your trip' } })
    const get = vi.spyOn(fake, 'getEvent')
    const patch = await request('/api/events/new-trip', 'PATCH', { blocksDay: false })
    expect(await patch.json()).toMatchObject({ event: { blocksDay: false, autoBlocksDay: true, blockingReason: 'Your trip' } })
    expect(get).not.toHaveBeenCalled()
    expect(fake.eventWrites).toHaveLength(1)
    const changed = await request('/api/events/new-trip', 'PUT', { ...input, summary: 'Birthday' })
    expect(await changed.json()).toMatchObject({ event: { blocksDay: false, autoBlocksDay: false, blockingReason: 'Birthday or anniversary' } })
    await request('/api/events/new-trip', 'PUT', { ...input, summary: 'Company holiday' })
    expect(await (await request('/api/events/new-trip')).json()).toMatchObject({ blocksDay: false, autoBlocksDay: true, blockingReason: 'Company holiday' })
    const writes = fake.eventWrites.length
    expect(await (await request('/api/events/new-trip', 'PATCH', { blocksDay: null })).json())
      .toMatchObject({ event: { blocksDay: null, autoBlocksDay: true, blockingReason: 'Company holiday' } })
    expect(fake.eventWrites).toHaveLength(writes)
    expect(get).not.toHaveBeenCalled()
    const synced = await (await request('/api/sync')).json() as { accounts: unknown[]; events: unknown[] }
    expect(synced.accounts).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: 'personal', displayName: 'Jordan Rivera' }),
      expect.objectContaining({ id: 'work', displayName: null }),
    ]))
    expect(synced.accounts.some((account) => Object.hasOwn(account as object, 'refreshTokenEnc'))).toBe(false)
    expect(synced.events).toEqual([expect.objectContaining({ id: 'new-trip', autoBlocksDay: true, blockingReason: 'Company holiday' })])
    expect(await (await request('/api/google/accounts')).json()).toMatchObject({ accounts: expect.arrayContaining([expect.objectContaining({ displayName: 'Jordan Rivera' })]) })
  })

  it('includes automatically blocked day names and reasons in unscheduled/Why here facts', async () => {
    await db.insert(events).values({ ...allDay, id: 'holiday', googleId: 'holiday', calendarId: gusto.id, summary: 'Veterans Day',
      autoBlocksDay: true, blockingReason: 'Company holiday' })
    await db.insert(tasks).values({ id: 'deadline', categoryId: 'inbox', title: 'Report', durationMinutes: 60, priority: 'medium',
      deadlineType: 'hard', dueAt: new Date('2026-11-10T00:00:00Z') })
    await runScheduling(db, testConfig, now)
    expect(await explainFacts(db, 'deadline', now)).toMatchObject({
      planned: [], unscheduled: { reason: 'no_fit_before_hard_deadline' },
      calendarBusyTime: { count: 1, first: [{ title: 'Veterans Day', blockingReason: 'Company holiday' }] },
    })
  })
})
