import { readFile } from 'node:fs/promises'
import { PGlite } from '@electric-sql/pglite'
import { describe, expect, it, vi } from 'vitest'
import { createApp } from '../src/app.js'
import { dailyFacts, explainFacts } from '../src/briefs.js'
import { calendars, dayOverrides, events, googleAccounts, routineBlocks, tasks } from '../src/db/schema.js'
import { runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'
import { FakeSync, testConfig } from './fixtures.js'

describe('calendar blocking migration', () => {
  it('preserves visibility and existing blocking choices, with blocking on for future rows', async () => {
    const client = new PGlite()
    try {
      await client.exec(`CREATE TABLE calendars (id text, selected boolean, updated_at timestamptz);
        INSERT INTO calendars VALUES ('work', true, '2026-01-01'), ('personal', true, '2026-01-01'),
        ('family', true, '2026-01-01'), ('coworker', false, '2026-01-01');`)
      await client.exec(await readFile(new URL('../drizzle/0007_fantastic_satana.sql', import.meta.url), 'utf8'))
      const result = await client.query('SELECT id, selected, blocks_scheduling FROM calendars ORDER BY id')
      expect(result.rows).toEqual([
        { id: 'coworker', selected: false, blocks_scheduling: false },
        { id: 'family', selected: true, blocks_scheduling: true },
        { id: 'personal', selected: true, blocks_scheduling: true },
        { id: 'work', selected: true, blocks_scheduling: true },
      ])
      await client.exec("INSERT INTO calendars (id, selected) VALUES ('new', false)")
      expect((await client.query("SELECT blocks_scheduling FROM calendars WHERE id = 'new'")).rows).toEqual([{ blocks_scheduling: true }])
      await client.exec(`CREATE TABLE events (id text, all_day boolean, transparency text);
        INSERT INTO events VALUES ('busy-holiday', true, 'opaque'), ('free-birthday', true, 'transparent');`)
      await client.exec(await readFile(new URL('../drizzle/0008_next_doomsday.sql', import.meta.url), 'utf8'))
      expect((await client.query('SELECT blocks_day FROM events')).rows).toEqual([{ blocks_day: null }, { blocks_day: null }])
    } finally {
      await client.close()
    }
  })
})

describe('named calendar constraints', () => {
  it('uses the scheduler override resolver for customized routines', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      await db.delete(routineBlocks)
      await db.insert(routineBlocks).values([
        { id: 'office', name: 'Office', days: [1], start: '09:00', end: '10:00', allows: ['office'] },
        { id: 'home', name: 'Home', days: [3], start: '14:00', end: '16:00', allows: ['home'] },
      ])
      await db.insert(dayOverrides).values({ date: '2026-11-12', kind: 'home' })
      await db.insert(googleAccounts).values({ id: 'account', email: 'me@example.com', label: 'me', refreshTokenEnc: 'unused' })
      await db.insert(calendars).values({ id: 'cal', accountId: 'account', googleId: 'cal', summary: 'Personal', accessRole: 'owner' })
      await db.insert(events).values({ id: 'appointment', calendarId: 'cal', googleId: 'appointment', status: 'confirmed',
        summary: 'Home appointment', allDay: false, startAt: new Date('2026-11-12T22:00:00Z'), endAt: new Date('2026-11-13T00:00:00Z') })
      await db.insert(tasks).values({ id: 'task', categoryId: 'inbox', title: 'Home task', durationMinutes: 60,
        priority: 'medium', deadlineType: 'none', context: 'home' })
      const now = new Date('2026-11-12T16:00:00Z')
      await runScheduling(db, { HORIZON_DAYS: 28 }, now)
      expect(await explainFacts(db, 'task', now)).toMatchObject({
        planned: [{ start: 'Wed 2026-11-18 14:00' }],
        calendarBusyTime: { count: 1, first: [{ title: 'Home appointment' }] },
      })
    } finally {
      await close()
    }
  })

  it('names hidden all-day and timed blockers in Why here and unscheduled facts, excluding free and special non-blockers', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      await db.insert(googleAccounts).values({ id: 'account', email: 'me@example.com', label: 'me', refreshTokenEnc: 'unused' })
      await db.insert(calendars).values([
        { id: 'hidden', accountId: 'account', googleId: 'hidden', summary: 'Hidden', accessRole: 'owner', selected: false },
        { id: 'display', accountId: 'account', googleId: 'display', summary: 'Display only', accessRole: 'reader', blocksScheduling: false },
      ])
      const event = { calendarId: 'hidden', status: 'confirmed', allDay: true,
        startAt: new Date('2026-11-09T00:00:00Z'), endAt: new Date('2026-11-10T00:00:00Z') }
      await db.insert(events).values([
        { ...event, id: 'away', googleId: 'away', summary: 'Veterans Day', blocksDay: true },
        { ...event, id: 'copy', googleId: 'copy', summary: 'Veterans Day', blocksDay: true },
        { ...event, id: 'birthday', googleId: 'birthday', summary: 'Birthday', transparency: 'transparent' },
        { ...event, id: 'focus', googleId: 'focus', summary: 'Focus time', eventType: 'focusTime' },
        { ...event, id: 'location', googleId: 'location', summary: 'At home', eventType: 'workingLocation' },
        { ...event, id: 'display', googleId: 'display', summary: 'Display only', calendarId: 'display' },
        { ...event, id: 'meeting', googleId: 'meeting', summary: 'Team meeting', allDay: false,
          startAt: new Date('2026-11-10T18:15:00Z'), endAt: new Date('2026-11-10T19:15:00Z') },
      ])
      await db.insert(tasks).values({ id: 'task', categoryId: 'inbox', title: 'Submit report', durationMinutes: 60,
        priority: 'medium', deadlineType: 'hard', dueAt: new Date('2026-11-10T00:00:00Z') })
      await db.insert(tasks).values({ id: 'later', categoryId: 'inbox', title: 'Next report', durationMinutes: 60,
        priority: 'medium', deadlineType: 'none' })
      const now = new Date('2026-11-09T16:00:00Z')
      await runScheduling(db, { HORIZON_DAYS: 28 }, now)
      const expected = { count: 1, first: [{ title: 'Veterans Day', start: 'Mon 2026-11-09 00:00', end: 'Tue 2026-11-10 00:00' }] }
      expect(await explainFacts(db, 'task', now)).toMatchObject({ planned: [], calendarBusyTime: expected,
        unscheduled: { reason: 'no_fit_before_hard_deadline' } })
      expect(await dailyFacts(db, now)).toMatchObject({ unscheduled: [{ title: 'Submit report', calendarBusyTime: expected }] })
      expect(await explainFacts(db, 'later', now)).toMatchObject({
        planned: [{ start: 'Tue 2026-11-10 11:15', end: '12:15' }],
        calendarBusyTime: { count: 2, first: [expected.first[0], { title: 'Team meeting', start: 'Tue 2026-11-10 10:15', end: 'Tue 2026-11-10 11:15' }] },
      })
    } finally {
      await close()
    }
  })
})

describe('Florida-only event annotation API', () => {
  it('changes one all-day occurrence on a read-only hidden calendar without Google I/O, syncs and reschedules', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      const now = new Date('2026-11-09T16:00:00Z')
      const fake = new FakeSync()
      const getGoogle = vi.spyOn(fake, 'getEvent')
      const app = createApp({ db, config: testConfig, sync: fake, reschedule: () => runScheduling(db, testConfig, now) })
      const request = (path: string, body?: unknown, method = 'PATCH') => app.request(path, {
        method, headers: { authorization: `Bearer ${testConfig.API_TOKEN}`, 'content-type': 'application/json' },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      })
      await db.insert(googleAccounts).values({ id: 'account', email: 'me@example.com', label: 'me', refreshTokenEnc: 'unused' })
      await db.insert(calendars).values({ id: 'cal', accountId: 'account', googleId: 'cal', summary: 'Holidays', accessRole: 'reader', selected: false })
      const occurrence = { calendarId: 'cal', status: 'confirmed', allDay: true, recurringEventId: 'annual',
        startAt: new Date('2026-11-09T00:00:00Z'), endAt: new Date('2026-11-10T00:00:00Z') }
      await db.insert(events).values([
        { ...occurrence, id: 'holiday', googleId: 'holiday', summary: 'Veterans Day', transparency: 'transparent' },
        { ...occurrence, id: 'next-year', googleId: 'next-year', summary: 'Veterans Day',
          startAt: new Date('2027-11-09T00:00:00Z'), endAt: new Date('2027-11-10T00:00:00Z') },
        { ...occurrence, id: 'school-break', googleId: 'school-break', summary: 'Amaia: Thanksgiving Break (No School)' },
        { ...occurrence, id: 'timed', googleId: 'timed', allDay: false,
          startAt: new Date('2026-11-10T20:00:00Z'), endAt: new Date('2026-11-10T21:00:00Z') },
        { ...occurrence, id: 'deleted', googleId: 'deleted', deletedAt: now },
      ])
      await db.insert(tasks).values({ id: 'task', categoryId: 'inbox', title: 'Report', durationMinutes: 60, priority: 'medium', deadlineType: 'none' })
      expect((await runScheduling(db, testConfig, now)).placements[0]?.start).toBe('2026-11-09T17:00:00.000Z')
      const cursor = ((await (await request('/api/sync', undefined, 'GET')).json()) as { cursor: string }).cursor
      const response = await request('/api/events/holiday', { blocksDay: true })
      expect(response.status).toBe(200)
      expect(await response.json()).toMatchObject({ event: { blocksDay: true, allDay: true },
        scheduling: { placements: [{ taskId: 'task', start: '2026-11-10T18:15:00.000Z' }] } })
      const synced = await (await request(`/api/sync?since=${encodeURIComponent(cursor)}`, undefined, 'GET')).json() as { events: { id: string; blocksDay: boolean }[] }
      expect(synced.events).toEqual([expect.objectContaining({ id: 'holiday', blocksDay: true })])
      expect(await (await request('/api/events/next-year', undefined, 'GET')).json()).toMatchObject({ blocksDay: null })
      expect(await (await request('/api/events/school-break', undefined, 'GET')).json()).toMatchObject({ blocksDay: null })
      expect((await request('/api/events/holiday', {
        calendarId: 'cal', summary: 'Veterans Day', allDay: true, blocksDay: false,
        startAt: occurrence.startAt.toISOString(), endAt: occurrence.endAt.toISOString(),
      }, 'PUT')).status).toBe(200)
      expect((await runScheduling(db, testConfig, now)).placements[0]?.start).toBe('2026-11-09T17:00:00.000Z')
      expect((await request('/api/events/holiday', { blocksDay: null })).status).toBe(200)
      expect(await (await request('/api/events/holiday', undefined, 'GET')).json()).toMatchObject({ blocksDay: null })
      await db.insert(events).values({ ...occurrence, id: 'ooo', googleId: 'ooo', eventType: 'outOfOffice' })
      expect((await runScheduling(db, testConfig, now)).placements[0]?.start).toBe('2026-11-10T18:15:00.000Z')
      expect((await request('/api/events/ooo', { blocksDay: false })).status).toBe(200)
      expect((await runScheduling(db, testConfig, now)).placements[0]?.start).toBe('2026-11-09T17:00:00.000Z')
      expect((await request('/api/events/ooo', { blocksDay: null })).status).toBe(200)
      expect((await runScheduling(db, testConfig, now)).placements[0]?.start).toBe('2026-11-10T18:15:00.000Z')
      expect((await request('/api/events/timed', { blocksDay: true })).status).toBe(400)
      expect((await request('/api/events/holiday', { blocksDay: true, scope: 'series' })).status).toBe(400)
      expect((await request('/api/events/holiday', { blocksDay: 'yes' })).status).toBe(400)
      expect((await request('/api/events/missing', { blocksDay: true })).status).toBe(404)
      expect((await request('/api/events/deleted', { blocksDay: true })).status).toBe(404)
      expect(fake.eventWrites).toEqual([])
      expect(getGoogle).not.toHaveBeenCalled()
    } finally {
      await close()
    }
  })
})
