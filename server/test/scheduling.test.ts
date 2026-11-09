import { eq } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import { placements, schedules, tasks, unscheduled } from '../src/db/schema.js'
import type { EventRow, CategoryRow, ScheduleRow, TaskRow } from '../src/db/schema.js'
import { buildSchedulerInput, runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'

const NOW = new Date('2026-11-09T17:00:00Z')
const T0 = new Date('2026-11-01T00:00:00Z')

function scheduleRow(id: string, over: Partial<ScheduleRow> = {}): ScheduleRow {
  return {
    id,
    name: id,
    timeZone: 'America/Los_Angeles',
    windows: [{ days: [1, 2, 3, 4, 5], start: '09:00', end: '17:00' }],
    createdAt: T0,
    updatedAt: T0,
    deletedAt: null,
    ...over,
  }
}

function categoryRow(id: string, scheduleId: string, over: Partial<CategoryRow> = {}): CategoryRow {
  return { id, name: id, color: null, scheduleId, sortOrder: 0, createdAt: T0, updatedAt: T0, deletedAt: null, ...over }
}

function taskRow(id: string, categoryId: string, over: Partial<TaskRow> = {}): TaskRow {
  return {
    id,
    categoryId,
    title: id,
    notes: null,
    durationMinutes: 60,
    minChunkMinutes: null,
    priority: 'medium',
    deadlineType: 'none',
    dueAt: null,
    startAt: null,
    scheduleId: null,
    pinnedStart: null,
    completedMinutes: 0,
    completedAt: null,
    createdAt: T0,
    updatedAt: T0,
    deletedAt: null,
    ...over,
  }
}

function eventRow(id: string, over: Partial<EventRow> = {}): EventRow {
  return {
    id,
    calendarId: 'cal',
    googleId: id,
    status: 'confirmed',
    summary: id,
    location: null,
    startAt: new Date('2026-11-10T18:00:00Z'),
    endAt: new Date('2026-11-10T19:00:00Z'),
    allDay: false,
    transparency: null,
    responseStatus: 'accepted',
    htmlLink: null,
    description: null,
    conferenceUrl: null,
    attendees: null,
    organizer: null,
    eventType: null,
    recurringEventId: null,
    icalUid: null,
    updatedAt: T0,
    deletedAt: null,
    ...over,
  }
}

const base = { now: NOW, horizonDays: 28, schedules: [scheduleRow('work'), scheduleRow('personal')] }

describe('buildSchedulerInput', () => {
  it('maps schedules, tasks and the horizon', () => {
    const input = buildSchedulerInput({
      ...base,
      categories: [categoryRow('inbox', 'work')],
      tasks: [
        taskRow('t1', 'inbox', {
          minChunkMinutes: 30,
          dueAt: new Date('2026-11-12T00:00:00Z'),
          startAt: new Date('2026-11-10T00:00:00Z'),
          completedMinutes: 15,
          deadlineType: 'soft',
        }),
      ],
      events: [],
    })
    expect(input.now).toBe('2026-11-09T17:00:00.000Z')
    expect(input.horizonDays).toBe(28)
    expect(input.schedules.map((s) => s.id)).toEqual(['work', 'personal'])
    expect(input.tasks).toEqual([
      {
        id: 't1',
        scheduleId: 'work',
        durationMinutes: 60,
        minChunkMinutes: 30,
        priority: 'medium',
        deadlineType: 'soft',
        dueAt: '2026-11-12T00:00:00.000Z',
        startAt: '2026-11-10T00:00:00.000Z',
        completedMinutes: 15,
        createdAt: '2026-11-01T00:00:00.000Z',
      },
    ])
  })

  it("falls back to the category's schedule and lets the task override win", () => {
    const input = buildSchedulerInput({
      ...base,
      categories: [categoryRow('inbox', 'work')],
      tasks: [taskRow('fallback', 'inbox'), taskRow('override', 'inbox', { scheduleId: 'personal' })],
      events: [],
    })
    expect(input.tasks.map((t) => [t.id, t.scheduleId])).toEqual([
      ['fallback', 'work'],
      ['override', 'personal'],
    ])
  })

  it('skips deleted, completed, and orphaned tasks and deleted schedules', () => {
    const input = buildSchedulerInput({
      ...base,
      schedules: [scheduleRow('work'), scheduleRow('old', { deletedAt: NOW })],
      categories: [categoryRow('inbox', 'work'), categoryRow('archived', 'work', { deletedAt: NOW })],
      tasks: [
        taskRow('open', 'inbox'),
        taskRow('deleted', 'inbox', { deletedAt: NOW }),
        taskRow('done', 'inbox', { completedAt: NOW }),
        taskRow('orphan', 'archived'),
        taskRow('no-category', 'missing'),
      ],
      events: [],
    })
    expect(input.schedules.map((s) => s.id)).toEqual(['work'])
    expect(input.tasks.map((t) => t.id)).toEqual(['open'])
  })

  it('turns only live, timed, opaque, not-declined events inside the horizon into busy time', () => {
    const input = buildSchedulerInput({
      ...base,
      categories: [],
      tasks: [],
      events: [
        eventRow('busy'),
        eventRow('all-day', { allDay: true, startAt: new Date('2026-11-10T00:00:00Z'), endAt: new Date('2026-11-11T00:00:00Z') }),
        eventRow('declined', { responseStatus: 'declined' }),
        eventRow('transparent', { transparency: 'transparent' }),
        eventRow('cancelled', { status: 'cancelled' }),
        eventRow('tombstone', { deletedAt: NOW }),
        eventRow('no-times', { startAt: null, endAt: null }),
        eventRow('past', { startAt: new Date('2026-11-01T18:00:00Z'), endAt: new Date('2026-11-01T19:00:00Z') }),
        eventRow('beyond-horizon', { startAt: new Date('2027-01-10T18:00:00Z'), endAt: new Date('2027-01-10T19:00:00Z') }),
        eventRow('straddles-now', { startAt: new Date('2026-11-09T16:30:00Z'), endAt: new Date('2026-11-09T17:30:00Z') }),
        eventRow('needs-action', { responseStatus: null }),
      ],
    })
    expect(input.busy).toEqual([
      { start: '2026-11-10T18:00:00.000Z', end: '2026-11-10T19:00:00.000Z' },
      { start: '2026-11-09T16:30:00.000Z', end: '2026-11-09T17:30:00.000Z' },
      { start: '2026-11-10T18:00:00.000Z', end: '2026-11-10T19:00:00.000Z' },
    ])
  })
})

describe('runScheduling', () => {
  it('replaces the unscheduled table wholesale next to placements', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      await db.insert(schedules).values(scheduleRow('doomed'))
      const insert = (row: TaskRow) => db.insert(tasks).values(row)
      await insert(taskRow('fits', 'inbox', { durationMinutes: 30 }))
      // Hard deadline already passed: none of its 45 minutes can be placed before it.
      await insert(taskRow('overdue', 'inbox', { durationMinutes: 45, deadlineType: 'hard', dueAt: new Date('2026-11-08T17:00:00Z') }))
      // Its schedule disappears below; 90 minutes with 30 already done leaves 60 unplaced.
      await insert(taskRow('homeless', 'inbox', { durationMinutes: 90, completedMinutes: 30, scheduleId: 'doomed' }))
      await db.update(schedules).set({ deletedAt: NOW }).where(eq(schedules.id, 'doomed'))

      await runScheduling(db, { HORIZON_DAYS: 28 }, NOW)
      const first = await db.select().from(unscheduled).orderBy(unscheduled.taskId)
      expect(first).toEqual([
        { taskId: 'homeless', reason: 'unknown_schedule', unplacedMinutes: 60, computedAt: NOW },
        { taskId: 'overdue', reason: 'no_fit_before_hard_deadline', unplacedMinutes: 45, computedAt: NOW },
      ])
      expect((await db.select().from(placements)).map((p) => p.taskId)).toEqual(['fits'])

      // Fixing one task and running again drops its row rather than leaving a stale one behind.
      await db.update(tasks).set({ scheduleId: null }).where(eq(tasks.id, 'homeless'))
      const later = new Date(NOW.getTime() + 60_000)
      await runScheduling(db, { HORIZON_DAYS: 28 }, later)
      expect(await db.select().from(unscheduled)).toEqual([
        { taskId: 'overdue', reason: 'no_fit_before_hard_deadline', unplacedMinutes: 45, computedAt: later },
      ])
    } finally {
      await close()
    }
  })
})
