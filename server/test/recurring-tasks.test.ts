import type { Hono } from 'hono'
import { eq } from 'drizzle-orm'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { createApp } from '../src/app.js'
import type { Db } from '../src/db/client.js'
import { taskRecurrences } from '../src/db/schema.js'
import { nextOccurrence, occurrenceDates, shiftRecurrenceInstant } from '../src/recurrence.js'
import type { RecurrenceRule } from '../src/recurrence.js'
import { runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { upsertTask } from '../src/tasks.js'
import type { TaskBody } from '../src/tasks.js'
import { createTestDb } from './db.js'
import { FakeSync, testConfig } from './fixtures.js'

const LA = 'America/Los_Angeles'
const MONTHLY: RecurrenceRule = { frequency: 'month', interval: 1, timeZone: LA, startDate: '2028-01-31', dayOfMonth: 31 }
const NOW = new Date('2028-01-31T16:00:00Z')

describe('calendar recurrence rules', () => {
  it('supports custom daily, multi-week/multi-weekday, monthly, quarterly and yearly intervals', () => {
    const cases: { rule: RecurrenceRule; through: string; dates: string[] }[] = [
      { rule: { ...MONTHLY, frequency: 'day', dayOfMonth: undefined, interval: 3 }, through: '2028-02-09', dates: ['2028-01-31', '2028-02-03', '2028-02-06', '2028-02-09'] },
      { rule: { frequency: 'week', interval: 2, timeZone: LA, startDate: '2028-01-31', weekdays: [1, 4] }, through: '2028-02-28', dates: ['2028-01-31', '2028-02-03', '2028-02-14', '2028-02-17', '2028-02-28'] },
      { rule: MONTHLY, through: '2028-05-31', dates: ['2028-01-31', '2028-02-29', '2028-03-31', '2028-04-30', '2028-05-31'] },
      { rule: { ...MONTHLY, interval: 3, dayOfMonth: 15 }, through: '2028-10-31', dates: ['2028-04-15', '2028-07-15', '2028-10-15'] },
      { rule: { ...MONTHLY, interval: 12 }, through: '2030-02-01', dates: ['2028-01-31', '2029-01-31', '2030-01-31'] },
    ]
    for (const { rule, through, dates } of cases) expect(occurrenceDates(rule, rule.startDate, through)).toEqual(dates)
  })

  it('honors inclusive ends, anchor weekdays, short non-leap months, and long gaps without backfill', () => {
    expect(occurrenceDates({ ...MONTHLY, endDate: '2028-02-29' }, '2028-01-31', '2029-01-31')).toEqual(['2028-01-31', '2028-02-29'])
    expect(nextOccurrence({ ...MONTHLY, endDate: '2028-02-29' }, '2028-03-01')).toBeUndefined()
    expect(nextOccurrence(MONTHLY, '2029-02-01')).toBe('2029-02-28')
    expect(nextOccurrence({ frequency: 'week', interval: 1, timeZone: LA, startDate: '2028-01-31' }, '2028-02-01')).toBe('2028-02-07')
    expect(occurrenceDates({ ...MONTHLY, interval: 12 }, '2040-02-01', '2040-03-01')).toEqual(['2041-01-31'])
  })

  it('keeps the local clock across both DST transitions, with defined gap/overlap behavior', () => {
    expect(shiftRecurrenceInstant('2026-03-01T17:00:00.000Z', '2026-03-01', '2026-03-08', LA).toISOString()).toBe('2026-03-08T16:00:00.000Z')
    expect(shiftRecurrenceInstant('2026-10-25T16:00:00.123Z', '2026-10-25', '2026-11-01', LA).toISOString()).toBe('2026-11-01T17:00:00.123Z')
    expect(shiftRecurrenceInstant('2026-03-01T10:30:00.000Z', '2026-03-01', '2026-03-08', LA).toISOString()).toBe('2026-03-08T10:30:00.000Z')
    expect(shiftRecurrenceInstant('2026-10-25T08:30:00.000Z', '2026-10-25', '2026-11-01', LA).toISOString()).toBe('2026-11-01T08:30:00.000Z')
  })
})

interface WireTask extends TaskBody {
  id: string
  recurrenceSeriesId: string | null
  recurrenceDate: string | null
  recurrenceRevision: string | null
  updatedAt: string
  deletedAt: string | null
}

let db: Db
let close: () => Promise<void>
let app: Hono
let clock = NOW
const config = { ...testConfig, HORIZON_DAYS: 125 }
const base: TaskBody = { categoryId: 'work', title: 'Pay bills', durationMinutes: 30, priority: 'medium', deadlineType: 'none' }

beforeAll(async () => {
  ;({ db, close } = await createTestDb())
  await seed(db)
  app = createApp({ db, config, sync: new FakeSync(), reschedule: () => runScheduling(db, config, clock) })
})
beforeEach(() => { clock = NOW })
afterAll(() => close())

async function request(path: string, method = 'GET', json?: unknown) {
  return app.request(path, {
    method,
    headers: { authorization: `Bearer ${config.API_TOKEN}`, 'content-type': 'application/json' },
    ...(json === undefined ? {} : { body: JSON.stringify(json) }),
  })
}

async function put(id: string, body: TaskBody & { recurrenceRevision?: string | null }): Promise<WireTask> {
  const response = await request(`/api/tasks/${id}`, 'PUT', { ...body, expectedRecurrenceRevision: body.recurrenceRevision ?? null })
  expect(response.status).toBe(200)
  return ((await response.json()) as { task: WireTask }).task
}

async function series(id: string | null): Promise<WireTask[]> {
  const response = await request('/api/sync')
  const data = (await response.json()) as { tasks: WireTask[] }
  return data.tasks.filter((task) => task.recurrenceSeriesId === id).sort((a, b) => (a.recurrenceDate ?? '').localeCompare(b.recurrenceDate ?? ''))
}

async function get(id: string): Promise<WireTask> {
  const response = await request(`/api/tasks/${id}`)
  expect(response.status).toBe(200)
  return await response.json() as WireTask
}

describe('recurring tasks through the API and real scheduler', () => {
  it('copies sources to occurrences, preserves older edits, and propagates source edits and clearing', async () => {
    const source = { url: 'https://linear.app/acme/issue/ENG-12/fix', title: 'Linear ENG-12', kind: 'linear' as const }
    const first = await put('source-series', { ...base, source, recurrence: MONTHLY })
    const initial = await series(first.recurrenceSeriesId)
    expect(initial).toHaveLength(5)
    expect(initial.map((task) => task.source)).toEqual(Array.from({ length: 5 }, () => source))
    const { source: omitted, ...oldClient } = first
    await put(first.id, { ...oldClient, title: 'Older client edit' })
    expect((await series(first.recurrenceSeriesId)).every((task) => task.source?.url === source.url)).toBe(true)
    const replacement = { url: 'https://github.com/acme/app/issues/42', title: 'Issue #42 in acme/app', kind: 'github' as const }
    const current = await get(initial[1]!.id)
    await put(current.id, { ...current, source: replacement })
    const changed = await series(first.recurrenceSeriesId)
    expect(changed[0]?.source).toEqual(source)
    expect(changed.slice(1).every((task) => task.source?.url === replacement.url)).toBe(true)
    const cleared = await get(initial[2]!.id)
    await put(cleared.id, { ...cleared, source: null })
    const after = await series(first.recurrenceSeriesId)
    expect(after[1]?.source).toEqual(replacement)
    expect(after.slice(2).every((task) => task.source === null)).toBe(true)
    clock = new Date('2028-06-01T16:00:00Z')
    await runScheduling(db, config, clock)
    const expanded = (await series(first.recurrenceSeriesId)).filter((task) => task.recurrenceDate! >= '2028-06-01')
    expect(expanded.length).toBeGreaterThan(0)
    expect(expanded.every((task) => task.source === null)).toBe(true)
    expect((await request(`/api/tasks/${first.id}`, 'DELETE')).status).toBe(200)
  })

  it('materializes older recurrence templates that have no source field as null', async () => {
    const first = await put('legacy-source-series', { ...base, recurrence: MONTHLY })
    const [stored] = await db.select().from(taskRecurrences).where(eq(taskRecurrences.id, first.recurrenceSeriesId!))
    const { source, ...legacy } = stored!.template
    await db.update(taskRecurrences).set({ template: legacy }).where(eq(taskRecurrences.id, first.recurrenceSeriesId!))
    clock = new Date('2028-06-01T16:00:00Z')
    await runScheduling(db, config, clock)
    const expanded = (await series(first.recurrenceSeriesId)).filter((task) => task.recurrenceDate! >= '2028-06-01')
    expect(expanded.length).toBeGreaterThan(0)
    expect(expanded.every((task) => task.source === null)).toBe(true)
    expect((await request(`/api/tasks/${first.id}`, 'DELETE')).status).toBe(200)
  })

  it('keeps Someday recurrence off plan through edits and expansion, then generates normal dates when reenabled', async () => {
    const first = await put('decision-series', { ...base, someday: true, recurrence: MONTHLY })
    const initial = await series(first.recurrenceSeriesId)
    expect(initial).toHaveLength(5)
    expect(initial.every((task) => task.someday === true && task.deadlineType === 'none' && task.dueAt === null && task.pinnedStart === null)).toBe(true)
    const { someday, ...oldClient } = first
    const edited = await put(first.id, { ...oldClient, title: 'Legacy edit keeps decision' })
    expect(edited.someday).toBe(true)
    clock = new Date('2028-08-01T16:00:00Z')
    const deferred = await runScheduling(db, config, clock)
    const expanded = await series(first.recurrenceSeriesId)
    expect(expanded.length).toBeGreaterThan(initial.length)
    expect(expanded.every((task) => task.someday === true && task.deadlineType === 'none' && task.dueAt === null)).toBe(true)
    const ids = new Set(expanded.map((task) => task.id))
    for (const artifacts of [deferred.placements, deferred.optional, deferred.unscheduled, deferred.late]) {
      expect(artifacts.some((artifact) => ids.has(artifact.taskId))).toBe(false)
    }
    const response = await request(`/api/tasks/${first.id}`, 'PATCH', { someday: false })
    expect(response.status).toBe(200)
    const changed = await series(first.recurrenceSeriesId)
    expect(changed.every((task) => task.someday === false)).toBe(true)
    expect(changed.every((task) => task.dueAt !== null)).toBe(true)
    clock = new Date('2029-03-01T16:00:00Z')
    await runScheduling(db, config, clock)
    const later = await series(first.recurrenceSeriesId)
    expect(later.length).toBeGreaterThan(changed.length)
    expect(later.every((task) => task.someday === false && task.dueAt !== null)).toBe(true)
    await request(`/api/tasks/${first.id}`, 'DELETE')
  })

  it('date edits reactivate a Someday series while toggling it on keeps release dates but clears pins and due dates', async () => {
    const first = await put('decision-dates', { ...base, recurrence: MONTHLY, pinnedStart: '2028-01-31T18:00:00Z' })
    const enabled = await request(`/api/tasks/${first.id}`, 'PATCH', { someday: true })
    expect(enabled.status).toBe(200)
    const deferred = await series(first.recurrenceSeriesId)
    expect(deferred.every((t) => t.someday === true && t.startAt !== null && t.pinnedStart === null && t.dueAt === null)).toBe(true)
    const renamed = await request(`/api/tasks/${first.id}`, 'PATCH', { title: 'Still deferred' })
    expect(renamed.status).toBe(200)
    expect((await series(first.recurrenceSeriesId)).every((t) => t.someday === true)).toBe(true)
    const moved = await request(`/api/tasks/${first.id}`, 'PATCH', { startAt: '2028-01-31T19:00:00Z' })
    expect(moved.status).toBe(200)
    expect((await series(first.recurrenceSeriesId)).every((t) => t.someday === false && t.dueAt !== null)).toBe(true)
    await request(`/api/tasks/${first.id}`, 'DELETE')
    })

  it('materializes independent month-end occurrences, exposes them through sync, and never schedules before their release', async () => {
    const first = await put('monthly', { ...base, recurrence: MONTHLY })
    const occurrences = await series(first.recurrenceSeriesId)
    expect(occurrences.map((task) => task.recurrenceDate)).toEqual(['2028-01-31', '2028-02-29', '2028-03-31', '2028-04-30', '2028-05-31'])
    expect(first).toMatchObject({ recurrence: MONTHLY, deadlineType: 'soft', startAt: '2028-01-31T08:00:00.000Z', dueAt: '2028-02-01T07:59:59.999Z' })
    expect(occurrences[2]).toMatchObject({ startAt: '2028-03-31T07:00:00.000Z', dueAt: '2028-04-01T06:59:59.999Z' })
    const response = await request('/api/sync')
    const sync = await response.json() as { placements: { taskId: string; startAt: string }[] }
    expect(sync.placements.some((block) => block.taskId === first.id)).toBe(true)
    for (const task of occurrences) {
      for (const block of sync.placements.filter((block) => block.taskId === task.id)) {
        expect(new Date(block.startAt).getTime()).toBeGreaterThanOrEqual(new Date(task.startAt!).getTime())
      }
    }
    await Promise.all([runScheduling(db, config, clock), runScheduling(db, config, clock)])
    expect(await series(first.recurrenceSeriesId)).toEqual(occurrences)
  })

  it('files every occurrence under the project and attention of the task it repeats, and follows a later edit', async () => {
    for (const id of ['series-atlas', 'series-billing']) {
      expect((await request(`/api/projects/${id}`, 'PUT', { name: id, parallel: true })).status).toBe(200)
    }
    const first = await put('project-series', { ...base, projectId: 'series-atlas', attention: 'full', recurrence: MONTHLY })
    const filed = (await series(first.recurrenceSeriesId)) as (WireTask & { projectId: string | null; attention: string | null })[]
    expect(filed).toHaveLength(5)
    expect(filed.map((task) => [task.projectId, task.attention])).toEqual(Array.from({ length: 5 }, () => ['series-atlas', 'full']))

    // Moving one occurrence to another project moves the ones after it, like any other edit of a series.
    await put(filed[1]!.id, { ...filed[1]!, projectId: 'series-billing', attention: null })
    const moved = (await series(first.recurrenceSeriesId)) as typeof filed
    expect(moved.filter((task) => task.deletedAt === null).map((task) => [task.recurrenceDate, task.projectId, task.attention])).toEqual([
      ['2028-01-31', 'series-atlas', 'full'],
      ['2028-02-29', 'series-billing', null],
      ['2028-03-31', 'series-billing', null],
      ['2028-04-30', 'series-billing', null],
      ['2028-05-31', 'series-billing', null],
    ])
    expect((await request(`/api/tasks/${first.id}`, 'DELETE')).status).toBe(200)
  })

  it('retries a recurring creation without duplicating the series or losing generated start/due dates', async () => {
    const body = { ...base, recurrence: { ...MONTHLY, dayOfMonth: 15 } }
    const first = await put('retry-series', body)
    const before = await series(first.recurrenceSeriesId)
    const retry = await put('retry-series', body)
    expect({ ...retry, updatedAt: first.updatedAt }).toEqual(first)
    const after = await series(first.recurrenceSeriesId)
    expect(after.filter((task) => task.id !== first.id)).toEqual(before.filter((task) => task.id !== first.id))
  })

  it('retries a legacy recurring creation with an explicit date and a missing source template field', async () => {
    const body = {
      ...base,
      dueAt: '2028-01-31T23:00:00.000Z',
      deadlineType: 'soft' as const,
      recurrence: { ...MONTHLY, dayOfMonth: 15 },
    }
    const first = await put('legacy-explicit-retry', body)
    expect(first.recurrenceDate).toBe('2028-02-15')
    expect(first.dueAt).toBe('2028-02-15T23:00:00.000Z')
    const [stored] = await db.select().from(taskRecurrences).where(eq(taskRecurrences.id, first.recurrenceSeriesId!))
    const { source, ...legacy } = stored!.template
    await db.update(taskRecurrences).set({ template: legacy }).where(eq(taskRecurrences.id, first.recurrenceSeriesId!))
    const before = await series(first.recurrenceSeriesId)
    const retry = await put(first.id, body)
    expect({ ...retry, updatedAt: first.updatedAt }).toEqual(first)
    const after = await series(first.recurrenceSeriesId)
    expect(after.filter((task) => task.id !== first.id)).toEqual(before.filter((task) => task.id !== first.id))
  })

  it('completes just one occurrence from an older client and preserves completed history when editing future tasks', async () => {
    const first = await put('history', { ...base, recurrence: MONTHLY })
    const initial = await series(first.recurrenceSeriesId)
    const { recurrence, ...oldClient } = first
    const done = await put(first.id, { ...oldClient, completedAt: NOW.toISOString(), completedMinutes: 30 })
    expect(done.recurrence).toEqual(MONTHLY)
    const april = initial[3]!
    const aprilDone = await put(april.id, { ...april, completedAt: NOW.toISOString(), completedMinutes: 30 })
    const february = initial[1]!
    await put(february.id, { ...february, title: 'Pay updated bills' })
    const changed = await series(first.recurrenceSeriesId)
    expect(changed[0]).toEqual(done)
    expect(changed[3]).toEqual(aprilDone)
    expect(changed.filter((task) => task.completedAt == null).map((task) => task.title)).toEqual(['Pay updated bills', 'Pay updated bills', 'Pay updated bills'])
    expect(changed[2]?.dueAt).toBe('2028-04-01T06:59:59.999Z')
  })

  it('reconciles a changed interval and stops repeats without removing the selected task or completed history', async () => {
    const rule: RecurrenceRule = { frequency: 'week', interval: 1, timeZone: LA, startDate: '2028-01-31', weekdays: [1] }
    const first = await put('edit-rule', { ...base, recurrence: rule })
    const initial = await series(first.recurrenceSeriesId)
    const completed = await put(initial[1]!.id, { ...initial[1]!, completedAt: NOW.toISOString(), completedMinutes: 30 })
    const changed = await put(first.id, { ...first, recurrence: { ...rule, interval: 2 } })
    const after = await series(first.recurrenceSeriesId)
    expect(after.find((task) => task.id === completed.id)).toEqual(completed)
    expect(after.find((task) => task.recurrenceDate === '2028-02-21')?.deletedAt).not.toBeNull()
    expect(after.find((task) => task.recurrenceDate === '2028-02-14')?.deletedAt).toBeNull()
    const standalone = await put(first.id, { ...changed, recurrence: null })
    expect(standalone).toMatchObject({ recurrence: null, recurrenceSeriesId: null, recurrenceDate: null, deletedAt: null })
    const stopped = await series(first.recurrenceSeriesId)
    expect(stopped.filter((task) => task.deletedAt === null)).toEqual([completed])
    clock = new Date('2030-01-01T16:00:00Z')
    await runScheduling(db, config, clock)
    expect(await series(first.recurrenceSeriesId)).toEqual(stopped)
    expect(await get(first.id)).toEqual(standalone)
  })

  it('deleting an occurrence stops its series, keeps earlier unfinished tasks, and cannot restart via a stale write', async () => {
    const first = await put('delete-series', { ...base, recurrence: MONTHLY })
    const initial = await series(first.recurrenceSeriesId)
    const selected = initial[1]!
    expect((await request(`/api/tasks/${selected.id}`, 'DELETE')).status).toBe(200)
    expect(await get(first.id)).toMatchObject({ recurrence: null, deletedAt: null })
    expect((await get(selected.id)).deletedAt).not.toBeNull()
    const staleCompletion = await request(`/api/tasks/${initial[2]!.id}`, 'PUT', {
      ...initial[2]!, expectedRecurrenceRevision: initial[2]!.recurrenceRevision,
      completedAt: NOW.toISOString(), completedMinutes: 30,
    })
    expect(staleCompletion.status).toBe(409)
    const tombstone = await get(initial[2]!.id)
    expect(tombstone.deletedAt).not.toBeNull()
    const restored = await put(tombstone.id, { ...tombstone, completedAt: NOW.toISOString(), completedMinutes: 30 })
    expect(restored.recurrence).toBeNull()
    expect(restored.recurrenceSeriesId).toBeNull()
    const stopped = await series(first.recurrenceSeriesId)
    clock = new Date('2031-01-31T16:00:00Z')
    await runScheduling(db, config, clock)
    expect(await series(first.recurrenceSeriesId)).toEqual(stopped)
  })

  it.each(['selected', 'earlier'] as const)('does not restart a stopped series from a stale %s snapshot, but permits deliberate enabling', async (which) => {
    const first = await put(`stale-stop-${which}`, { ...base, recurrence: MONTHLY })
    const initial = await series(first.recurrenceSeriesId)
    if (which === 'selected') await put(first.id, { ...first, recurrence: null })
    else expect((await request(`/api/tasks/${initial[1]!.id}`, 'DELETE')).status).toBe(200)
    const stopped = await get(first.id)
    const stale = await request(`/api/tasks/${first.id}`, 'PUT', {
      ...first, expectedRecurrenceRevision: first.recurrenceRevision,
      completedAt: NOW.toISOString(), completedMinutes: 30,
    })
    expect(stale.status).toBe(409)
    expect(await get(first.id)).toEqual(stopped)
    const completed = await request(`/api/tasks/${first.id}`, 'PATCH', { completedAt: NOW.toISOString(), completedMinutes: 30 })
    expect(completed.status).toBe(200)
    expect(await get(first.id)).toMatchObject({ recurrence: null, recurrenceSeriesId: null, completedAt: NOW.toISOString() })
    const restarted = await put(first.id, { ...await get(first.id), completedAt: null, completedMinutes: 0, recurrence: MONTHLY })
    expect(restarted.recurrenceSeriesId).not.toBe(first.recurrenceSeriesId)
    expect(restarted.recurrence).toEqual(MONTHLY)
    expect((await series(first.recurrenceSeriesId)).every((task) => task.deletedAt !== null)).toBe(true)
  })

  it.each(['deleted', 'completed'] as const)('cannot re-enable repeats by retrying the same %s occurrence restore', async (which) => {
    const first = await put(`restore-retry-${which}`, { ...base, recurrence: MONTHLY })
    const initial = await series(first.recurrenceSeriesId)
    let snapshot: WireTask
    if (which === 'deleted') {
      expect((await request(`/api/tasks/${first.id}`, 'DELETE')).status).toBe(200)
      snapshot = await get(first.id)
    } else {
      expect((await request(`/api/tasks/${first.id}`, 'PATCH', { completedAt: NOW.toISOString(), completedMinutes: 30 })).status).toBe(200)
      snapshot = await get(first.id)
      expect((await request(`/api/tasks/${initial[1]!.id}`, 'DELETE')).status).toBe(200)
    }
    const body = { ...snapshot, expectedRecurrenceRevision: snapshot.recurrenceRevision }
    const restored = await request(`/api/tasks/${first.id}`, 'PUT', body)
    expect(restored.status).toBe(200)
    const oneOff = await get(first.id)
    expect(oneOff).toMatchObject({ recurrence: null, recurrenceSeriesId: null, deletedAt: null })
    const beforeRetry = await series(first.recurrenceSeriesId)
    expect((await request(`/api/tasks/${first.id}`, 'PUT', body)).status).toBe(409)
    expect(await get(first.id)).toEqual(oneOff)
    expect(await series(first.recurrenceSeriesId)).toEqual(beforeRetry)
    const enabled = await put(first.id, { ...oneOff, recurrence: MONTHLY })
    expect(enabled.recurrence).toEqual(MONTHLY)
    expect(enabled.recurrenceSeriesId).not.toBe(first.recurrenceSeriesId)
  })

  it('restores a deleted occurrence as an explicit one-off with the pre-delete revision, including retries', async () => {
    const first = await put('explicit-undo', { ...base, recurrence: MONTHLY })
    expect((await request(`/api/tasks/${first.id}`, 'DELETE')).status).toBe(200)
    const stopped = await series(first.recurrenceSeriesId)
    const body = { ...first, recurrence: null, expectedRecurrenceRevision: first.recurrenceRevision }
    for (let attempt = 0; attempt < 2; attempt++) {
      expect((await request(`/api/tasks/${first.id}`, 'PUT', body)).status).toBe(200)
      const restored = await get(first.id)
      expect(restored).toMatchObject({ recurrence: null, recurrenceSeriesId: null, recurrenceDate: null, deletedAt: null })
      expect(restored.recurrenceRevision).not.toBe(first.recurrenceRevision)
      expect(await series(first.recurrenceSeriesId)).toEqual(stopped.filter((task) => task.id !== first.id))
    }
  })

  it('applies offline completion and reopen without reverting newer series edits or resurrecting excluded dates', async () => {
    const rule: RecurrenceRule = { frequency: 'week', interval: 1, timeZone: LA, startDate: '2028-01-31', weekdays: [1] }
    const first = await put('offline-completion', { ...base, title: 'Original', recurrence: rule })
    const offline = (await series(first.recurrenceSeriesId)).find((task) => task.recurrenceDate === '2028-02-14')!
    await put(first.id, { ...first, title: 'Edited online', recurrence: { ...rule, interval: 2 } })
    const before = await series(first.recurrenceSeriesId)
    const stale = await request(`/api/tasks/${offline.id}`, 'PUT', {
      ...offline, expectedRecurrenceRevision: offline.recurrenceRevision,
      completedAt: NOW.toISOString(), completedMinutes: 30,
    })
    expect(stale.status).toBe(409)
    for (const completedAt of [NOW.toISOString(), null]) {
      const response = await request(`/api/tasks/${offline.id}`, 'PATCH', { completedAt, completedMinutes: completedAt === null ? 0 : 30 })
      expect(response.status).toBe(200)
      const after = await series(first.recurrenceSeriesId)
      expect(after.filter((task) => task.id !== offline.id)).toEqual(before.filter((task) => task.id !== offline.id))
      expect(await get(offline.id)).toMatchObject({ title: 'Edited online', recurrence: { ...rule, interval: 2 }, completedAt })
      expect(after.find((task) => task.recurrenceDate === '2028-02-21')?.deletedAt).not.toBeNull()
    }
  })

  it('generates all replacement future dates when an earlier occurrence is edited after a later edit', async () => {
    const first = await put('earlier-boundary', { ...base, recurrence: MONTHLY })
    const initial = await series(first.recurrenceSeriesId)
    await put(initial[3]!.id, { ...initial[3]!, title: 'Edited in April' })
    const february = await get(initial[1]!.id)
    await put(february.id, { ...february, recurrence: { ...MONTHLY, dayOfMonth: 15 } })
    const live = (await series(first.recurrenceSeriesId)).filter((task) => task.deletedAt === null)
    expect(live.map((task) => task.recurrenceDate)).toEqual(['2028-01-31', '2028-02-29', '2028-03-15', '2028-04-15', '2028-05-15'])
    expect(live[0]).toEqual(first)
  })

  it('keeps a long-interval next occurrence visible and resumes after downtime without historical backfill', async () => {
    const first = await put('yearly', { ...base, recurrence: { ...MONTHLY, interval: 12 } })
    expect((await series(first.recurrenceSeriesId)).map((task) => task.recurrenceDate)).toEqual(['2028-01-31'])
    clock = new Date('2035-02-01T16:00:00Z')
    const backdated = await upsertTask(db, 'backdated-yearly', { ...base, recurrence: { ...MONTHLY, interval: 12 } }, clock)
    expect(backdated.recurrenceDate).toBe('2036-01-31')
    await runScheduling(db, config, clock)
    expect((await series(first.recurrenceSeriesId)).map((task) => task.recurrenceDate)).toEqual(['2028-01-31', '2036-01-31'])
    expect((await series(backdated.recurrenceSeriesId)).map((task) => task.recurrenceDate)).toEqual(['2036-01-31'])
  })

  it('moves recurrence templates to Inbox with their category, so newly generated tasks stay usable', async () => {
    expect((await request('/api/categories/recurring-category', 'PUT', { name: 'Recurring', scheduleId: 'work' })).status).toBe(200)
    const first = await put('category-series', { ...base, categoryId: 'recurring-category', recurrence: MONTHLY })
    expect((await request('/api/categories/recurring-category', 'DELETE')).status).toBe(200)
    clock = new Date('2028-08-01T16:00:00Z')
    await runScheduling(db, config, clock)
    expect((await series(first.recurrenceSeriesId)).every((task) => task.categoryId === 'inbox')).toBe(true)
  })

  it('rejects invalid rules and impossible end dates without writing a task', async () => {
    const invalid = [
      { ...MONTHLY, interval: 0 }, { ...MONTHLY, interval: 1.5 }, { ...MONTHLY, dayOfMonth: 32 },
      { ...MONTHLY, startDate: '2028-02-30' }, { ...MONTHLY, timeZone: 'Invalid/Zone' },
      { ...MONTHLY, endDate: '2027-01-01' }, { ...MONTHLY, weekdays: [1] },
      { frequency: 'week', interval: 1, timeZone: LA, startDate: '2028-01-31', weekdays: [] },
      { frequency: 'week', interval: 1, timeZone: LA, startDate: '2028-01-31', weekdays: [1, 1] },
      { ...MONTHLY, startDate: '2020-01-01', endDate: '2020-02-01' },
    ]
    for (const recurrence of invalid) {
      expect((await request('/api/tasks/invalid-recurrence', 'PUT', { ...base, recurrence })).status).toBe(400)
    }
    expect((await request('/api/tasks/invalid-recurrence')).status).toBe(404)
  })
})
