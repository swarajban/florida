import { eq, inArray } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import { optionalPlacements, placements, routineBlocks, tasks, unscheduled } from '../src/db/schema.js'
import type { EventRow, CategoryRow, RoutineBlockRow, TaskRow } from '../src/db/schema.js'
import { buildSchedulerInput, runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'

const NOW = new Date('2026-11-09T17:00:00Z')
const T0 = new Date('2026-11-01T00:00:00Z')
const LA = 'America/Los_Angeles'

function routineBlockRow(id: string, over: Partial<RoutineBlockRow> = {}): RoutineBlockRow {
  return {
    id,
    name: id,
    days: [1, 2, 3, 4, 5],
    start: '09:00',
    end: '17:00',
    allows: ['computer', 'errand', 'home', 'office'],
    optional: false,
    createdAt: T0,
    updatedAt: T0,
    deletedAt: null,
    ...over,
  }
}

function categoryRow(id: string, over: Partial<CategoryRow> = {}): CategoryRow {
  return {
    id,
    name: id,
    color: null,
    area: null,
    scheduleId: 'work',
    sortOrder: 0,
    createdAt: T0,
    updatedAt: T0,
    deletedAt: null,
    ...over,
  }
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
    context: 'computer',
    pinnedStart: null,
    recurrence: null,
    recurrenceSeriesId: null,
    recurrenceDate: null,
    recurrenceRevision: null,
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

const base = { now: NOW, horizonDays: 28, timeZone: LA, routineBlocks: [routineBlockRow('work')] }

describe('buildSchedulerInput', () => {
  it('maps the routine, tasks and the horizon', () => {
    const input = buildSchedulerInput({
      ...base,
      categories: [categoryRow('inbox')],
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
    expect(input.routine).toEqual({
      timeZone: LA,
      blocks: [{ id: 'work', days: [1, 2, 3, 4, 5], start: '09:00', end: '17:00', allows: ['computer', 'errand', 'home', 'office'] }],
    })
    expect(input.tasks).toEqual([
      {
        id: 't1',
        context: 'computer',
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

  it("carries each task's own context; the category has no say", () => {
    const input = buildSchedulerInput({
      ...base,
      categories: [categoryRow('inbox'), categoryRow('work', { area: 'work' })],
      tasks: [taskRow('desk', 'inbox'), taskRow('ups-return', 'inbox', { context: 'errand' }), taskRow('badge', 'work', { context: 'office' })],
      events: [],
    })
    expect(input.tasks.map((t) => [t.id, t.context])).toEqual([
      ['desk', 'computer'],
      ['ups-return', 'errand'],
      ['badge', 'office'],
    ])
  })

  it('marks optional blocks and gives each task the area of its category', () => {
    const input = buildSchedulerInput({
      ...base,
      routineBlocks: [routineBlockRow('work'), routineBlockRow('evening', { start: '20:00', end: '23:00', optional: true })],
      categories: [categoryRow('inbox'), categoryRow('house', { area: 'personal' }), categoryRow('eng', { area: 'work' })],
      tasks: [taskRow('unfiled', 'inbox'), taskRow('paint', 'house'), taskRow('review', 'eng')],
      events: [],
    })
    expect(input.routine.blocks.map((b) => [b.id, b.optional])).toEqual([
      ['work', undefined],
      ['evening', true],
    ])
    expect(input.tasks.map((t) => [t.id, t.area])).toEqual([
      ['unfiled', undefined],
      ['paint', 'personal'],
      ['review', 'work'],
    ])
  })

  it('skips deleted, completed, and orphaned tasks and deleted routine blocks', () => {
    const input = buildSchedulerInput({
      ...base,
      routineBlocks: [routineBlockRow('work'), routineBlockRow('old', { deletedAt: NOW })],
      categories: [categoryRow('inbox'), categoryRow('archived', { deletedAt: NOW })],
      tasks: [
        taskRow('open', 'inbox'),
        taskRow('deleted', 'inbox', { deletedAt: NOW }),
        taskRow('done', 'inbox', { completedAt: NOW }),
        taskRow('orphan', 'archived'),
        taskRow('no-category', 'missing'),
      ],
      events: [],
    })
    expect(input.routine.blocks.map((b) => b.id)).toEqual(['work'])
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
  it('keeps a block the user is in the middle of where it was', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      // NOW is 09:00 Monday in Los Angeles, the start of the seeded home block: the first run puts
      // the hour-long task right at 09:00.
      await db.insert(tasks).values(taskRow('deep-work', 'inbox'))
      await runScheduling(db, { HORIZON_DAYS: 28 }, NOW)
      expect(await db.select({ startAt: placements.startAt, endAt: placements.endAt }).from(placements)).toEqual([
        { startAt: new Date('2026-11-09T17:00:00Z'), endAt: new Date('2026-11-09T18:00:00Z') },
      ])

      // Ten minutes in, something unrelated triggers a rerun. A fresh plan would start the block
      // at 09:15 (the next grid point); the block in progress must stay at 09:00–10:00.
      const tenMinutesIn = new Date('2026-11-09T17:10:00Z')
      await runScheduling(db, { HORIZON_DAYS: 28 }, tenMinutesIn)
      expect(await db.select({ startAt: placements.startAt, endAt: placements.endAt }).from(placements)).toEqual([
        { startAt: new Date('2026-11-09T17:00:00Z'), endAt: new Date('2026-11-09T18:00:00Z') },
      ])
    } finally {
      await close()
    }
  })

  it('stores evening suggestions apart from the plan and replaces them on every run', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      // Monday's home block (09:00–15:30) is exactly filled, so the hour-long task is planned for
      // Tuesday at the office: work the plan has not reached by Monday evening.
      await db.insert(tasks).values(taskRow('all-day', 'inbox', { durationMinutes: 390, createdAt: T0 }))
      await db.insert(tasks).values(taskRow('taxes', 'personal', { createdAt: new Date('2026-11-02T00:00:00Z') }))
      await runScheduling(db, { HORIZON_DAYS: 28 }, NOW)

      const plan = () => db.select({ taskId: placements.taskId, startAt: placements.startAt }).from(placements).orderBy(placements.startAt)
      const planned = [
        { taskId: 'all-day', startAt: new Date('2026-11-09T17:00:00Z') },
        { taskId: 'taxes', startAt: new Date('2026-11-10T18:15:00Z') },
      ]
      expect(await plan()).toEqual(planned)
      const suggested = await db.select().from(optionalPlacements)
      expect(suggested).toEqual([
        {
          id: expect.any(String),
          taskId: 'taxes',
          blockId: 'evening',
          // Monday 20:00–21:00 in Los Angeles. Not Tuesday: by then the plan has it done.
          startAt: new Date('2026-11-10T04:00:00Z'),
          endAt: new Date('2026-11-10T05:00:00Z'),
          computedAt: NOW,
        },
      ])

      // The next run feeds the plan back but not the suggestion: nothing moves into the evening.
      const later = new Date(NOW.getTime() + 60_000)
      const result = await runScheduling(db, { HORIZON_DAYS: 28 }, later)
      expect(await plan()).toEqual(planned)
      expect(result.optional).toEqual([
        { taskId: 'taxes', blockId: 'evening', start: '2026-11-10T04:00:00.000Z', end: '2026-11-10T05:00:00.000Z' },
      ])
      const replaced = await db.select().from(optionalPlacements)
      expect(replaced.map((p) => [p.taskId, p.computedAt])).toEqual([['taxes', later]])
      expect(replaced[0]?.id).not.toBe(suggested[0]?.id)
    } finally {
      await close()
    }
  })

  it('replaces the unscheduled table wholesale next to placements', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      const insert = (row: TaskRow) => db.insert(tasks).values(row)
      await insert(taskRow('fits', 'inbox', { durationMinutes: 30 }))
      // Hard deadline already passed: none of its 45 minutes can be placed before it.
      await insert(taskRow('overdue', 'inbox', { durationMinutes: 45, deadlineType: 'hard', dueAt: new Date('2026-11-08T17:00:00Z') }))
      // Office-only work with the office days removed from the routine; 90 minutes with 30 already
      // done leaves 60 unplaced.
      await insert(taskRow('homeless', 'inbox', { durationMinutes: 90, completedMinutes: 30, context: 'office' }))
      await db.update(routineBlocks).set({ deletedAt: NOW }).where(inArray(routineBlocks.id, ['office-tue', 'office-wed']))

      await runScheduling(db, { HORIZON_DAYS: 28 }, NOW)
      const first = await db.select().from(unscheduled).orderBy(unscheduled.taskId)
      expect(first).toEqual([
        { taskId: 'homeless', reason: 'no_allowed_block', unplacedMinutes: 60, computedAt: NOW },
        { taskId: 'overdue', reason: 'no_fit_before_hard_deadline', unplacedMinutes: 45, computedAt: NOW },
      ])
      expect((await db.select().from(placements)).map((p) => p.taskId)).toEqual(['fits'])

      // Fixing one task and running again drops its row rather than leaving a stale one behind.
      await db.update(tasks).set({ context: 'computer' }).where(eq(tasks.id, 'homeless'))
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
