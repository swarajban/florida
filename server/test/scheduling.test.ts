import { eq, inArray } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import {
  calendars,
  dayOverrides,
  events,
  googleAccounts,
  optionalPlacements,
  placements,
  planSummary,
  projectPlacements,
  projects,
  routineBlocks,
  routineOccurrences,
  tasks,
  unscheduled,
} from '../src/db/schema.js'
import type { EventRow, CategoryRow, ProjectPlacementRow, ProjectRow, RoutineBlockRow, TaskRow } from '../src/db/schema.js'
import { buildSchedulerInput, runScheduling, splitProjectTime } from '../src/scheduling.js'
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
    alternates: null,
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
    projectId: null,
    attention: null,
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

function projectRow(id: string, over: Partial<ProjectRow> = {}): ProjectRow {
  return {
    id,
    name: id,
    status: 'active',
    categoryId: null,
    notes: null,
    nextStep: null,
    parallel: false,
    weeklyMinutes: null,
    sortOrder: 0,
    createdAt: T0,
    updatedAt: T0,
    deletedAt: null,
    ...over,
  }
}

function projectTimeRow(id: string, projectId: string, weekOf: string, start: string, end: string): ProjectPlacementRow {
  return { id, projectId, weekOf, startAt: new Date(start), endAt: new Date(end), lane: null, computedAt: T0 }
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
        attention: 'full',
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

  it('leaves out tasks of a project that is not active, and takes attention from the project unless the task sets it', () => {
    const input = buildSchedulerInput({
      ...base,
      categories: [categoryRow('inbox')],
      projects: [
        projectRow('agents', { parallel: true }),
        projectRow('paused', { status: 'on_hold' }),
        projectRow('idea', { status: 'thinking' }),
        projectRow('shipped', { status: 'done' }),
        projectRow('gone', { status: 'on_hold', deletedAt: NOW }),
      ],
      tasks: [
        taskRow('follows', 'inbox', { projectId: 'agents' }),
        taskRow('focus', 'inbox', { projectId: 'agents', attention: 'full' }),
        taskRow('own-chunk', 'inbox', { projectId: 'agents', minChunkMinutes: 30 }),
        taskRow('pinned', 'inbox', { projectId: 'agents', pinnedStart: new Date('2026-11-10T18:00:00Z') }),
        taskRow('waiting', 'inbox', { projectId: 'paused' }),
        taskRow('someday', 'inbox', { projectId: 'idea' }),
        taskRow('leftover', 'inbox', { projectId: 'shipped' }),
        // A deleted project holds nothing back: its task is planned like any other.
        taskRow('orphan', 'inbox', { projectId: 'gone' }),
        taskRow('loose', 'inbox', { attention: 'shared' }),
      ],
      events: [],
    })
    expect(input.tasks.map((t) => [t.id, t.attention, t.projectId, t.minChunkMinutes])).toEqual([
      // Shared work without a chunk of its own splits into hour-long pieces, so lanes can interleave.
      ['follows', 'shared', 'agents', 60],
      ['focus', 'full', 'agents', undefined],
      ['own-chunk', 'shared', 'agents', 30],
      ['pinned', 'shared', 'agents', undefined],
      ['orphan', 'full', undefined, undefined],
      ['loose', 'shared', undefined, 60],
    ])
  })

  it('adds project time for the part of a weekly budget that open tasks and time already spent do not cover', () => {
    // NOW is a Monday: the local week runs from Sunday 2026-11-08 to Sunday 2026-11-15, both at
    // 08:00Z (Pacific standard time).
    const input = buildSchedulerInput({
      ...base,
      categories: [categoryRow('inbox'), categoryRow('eng', { area: 'work' })],
      projects: [
        projectRow('atlas', { weeklyMinutes: 300, categoryId: 'eng' }),
        projectRow('agents', { weeklyMinutes: 120, parallel: true }),
        projectRow('small', { weeklyMinutes: 60 }),
        projectRow('paused', { weeklyMinutes: 300, status: 'on_hold' }),
        projectRow('unbudgeted'),
      ],
      tasks: [
        // 60 of its 90 minutes are still open.
        taskRow('atlas-open', 'inbox', { projectId: 'atlas', durationMinutes: 90, completedMinutes: 30 }),
        taskRow('agents-open', 'inbox', { projectId: 'agents', durationMinutes: 200 }),
        taskRow('small-open', 'inbox', { projectId: 'small', durationMinutes: 40 }),
      ],
      events: [],
      projectPlacements: [
        // Ended this week: 45 minutes spent.
        projectTimeRow('spent', 'atlas', '2026-11-08', '2026-11-09T16:00:00Z', '2026-11-09T16:45:00Z'),
        // Last week's does not count against this week, and a block still ahead is not spent yet.
        projectTimeRow('last-week', 'atlas', '2026-11-01', '2026-11-06T17:00:00Z', '2026-11-06T18:00:00Z'),
        projectTimeRow('ahead', 'atlas', '2026-11-08', '2026-11-10T19:00:00Z', '2026-11-10T20:00:00Z'),
      ],
      completedProjectTasks: [
        taskRow('atlas-done', 'inbox', { projectId: 'atlas', durationMinutes: 50, completedAt: new Date('2026-11-08T20:00:00Z') }),
        // Saturday evening Pacific: before this week began.
        taskRow('atlas-old', 'inbox', { projectId: 'atlas', durationMinutes: 500, completedAt: new Date('2026-11-08T04:00:00Z') }),
      ],
    })
    const projectTime = input.tasks.filter((t) => t.id.startsWith('project-time:'))
    expect(projectTime.map((t) => [t.id, t.durationMinutes, t.attention, t.startAt, t.dueAt, t.area])).toEqual([
      // 300 − 45 spent − 50 completed − 60 open = 145, rounded down to the quarter hour.
      ['project-time:2026-11-08:atlas', 135, 'full', undefined, '2026-11-15T08:00:00.000Z', 'work'],
      ['project-time:2026-11-15:atlas', 300, 'full', '2026-11-15T08:00:00.000Z', '2026-11-22T08:00:00.000Z', 'work'],
      // 200 open minutes use up this week's 120 and 80 of next week's; 40 are left, rounded to 30.
      ['project-time:2026-11-15:agents', 30, 'shared', '2026-11-15T08:00:00.000Z', '2026-11-22T08:00:00.000Z', undefined],
      // 60 − 40 leaves 20 this week: too little to plan. Next week has the whole hour.
      ['project-time:2026-11-15:small', 60, 'full', '2026-11-15T08:00:00.000Z', '2026-11-22T08:00:00.000Z', undefined],
    ])
    for (const t of projectTime) {
      expect(t).toMatchObject({ priority: 'low', deadlineType: 'soft', context: 'computer', projectId: t.id.slice('project-time:2026-11-08:'.length) })
    }
  })
})

describe('splitProjectTime', () => {
  it('moves project time out of the plan, keeps only blocks inside their own week, and never reports it', () => {
    const block = (taskId: string, start: string, end: string, lane?: number) => ({
      taskId,
      start,
      end,
      pinned: false,
      ...(lane === undefined ? {} : { lane }),
    })
    const result = splitProjectTime(
      {
        placements: [
          block('t1', '2026-11-09T17:00:00.000Z', '2026-11-09T18:00:00.000Z'),
          block('project-time:2026-11-08:atlas', '2026-11-10T19:00:00.000Z', '2026-11-10T20:00:00.000Z', 1),
          // Saturday 23:30 Pacific is already Sunday in UTC, but still in the week that began on the 8th.
          block('project-time:2026-11-08:atlas', '2026-11-15T07:30:00.000Z', '2026-11-15T08:00:00.000Z'),
          // The scheduler could only fit this after its week ended: the budget is not carried over.
          block('project-time:2026-11-08:atlas', '2026-11-16T17:00:00.000Z', '2026-11-16T18:00:00.000Z'),
          block('project-time:2026-11-15:with:colon', '2026-11-16T18:00:00.000Z', '2026-11-16T19:00:00.000Z'),
        ],
        unscheduled: [
          { taskId: 'project-time:2026-11-08:atlas', reason: 'no_fit_in_horizon', unplacedMinutes: 30 },
          { taskId: 't2', reason: 'no_allowed_block', unplacedMinutes: 60 },
        ],
        late: [
          { taskId: 'project-time:2026-11-08:atlas', dueAt: '2026-11-15T08:00:00.000Z', eta: '2026-11-16T18:00:00.000Z' },
          { taskId: 't1', dueAt: '2026-11-09T17:30:00.000Z', eta: '2026-11-09T18:00:00.000Z' },
        ],
        optional: [
          { taskId: 'project-time:2026-11-08:atlas', blockId: 'evening', start: '2026-11-10T04:00:00.000Z', end: '2026-11-10T05:00:00.000Z' },
          { taskId: 't1', blockId: 'evening', start: '2026-11-10T05:00:00.000Z', end: '2026-11-10T06:00:00.000Z' },
        ],
        routine: [],
        missed: [],
        capacity: [],
      },
      LA,
    )
    expect(result.placements.map((p) => p.taskId)).toEqual(['t1'])
    expect(result.projectPlacements).toEqual([
      { projectId: 'atlas', weekOf: '2026-11-08', start: '2026-11-10T19:00:00.000Z', end: '2026-11-10T20:00:00.000Z', lane: 1 },
      { projectId: 'atlas', weekOf: '2026-11-08', start: '2026-11-15T07:30:00.000Z', end: '2026-11-15T08:00:00.000Z' },
      { projectId: 'with:colon', weekOf: '2026-11-15', start: '2026-11-16T18:00:00.000Z', end: '2026-11-16T19:00:00.000Z' },
    ])
    expect(result.unscheduled.map((u) => u.taskId)).toEqual(['t2'])
    expect(result.late.map((l) => l.taskId)).toEqual(['t1'])
    expect(result.optional.map((o) => o.taskId)).toEqual(['t1'])
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

  it('stores lanes, the gym and each day\'s capacity, and keeps project time that has ended as time spent', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      await db.insert(projects).values([projectRow('atlas', { parallel: true, weeklyMinutes: 120 }), projectRow('billing', { parallel: true })])
      await db.insert(tasks).values([
        taskRow('atlas-task', 'inbox', { projectId: 'atlas' }),
        taskRow('billing-task', 'inbox', { projectId: 'billing', createdAt: new Date('2026-11-02T00:00:00Z') }),
      ])
      const result = await runScheduling(db, { HORIZON_DAYS: 28 }, NOW)

      // Atlas reserves two hours a week and its task covers one, so one hour of project time is
      // planned this week and the full two next week. Project time is due by the end of its week,
      // so it is planned ahead of the undated tasks: 09:00 Monday. The Atlas task follows it (a
      // project never runs beside itself) and the Billing task runs alongside, in the next lane.
      const lanes = () =>
        db.select({ taskId: placements.taskId, startAt: placements.startAt, lane: placements.lane }).from(placements).orderBy(placements.lane)
      expect(await lanes()).toEqual([
        { taskId: 'atlas-task', startAt: new Date('2026-11-09T18:00:00Z'), lane: 0 },
        { taskId: 'billing-task', startAt: NOW, lane: 1 },
      ])

      const minutesByWeek = async () => {
        const rows = await db.select().from(projectPlacements).orderBy(projectPlacements.startAt)
        const byWeek: Record<string, number> = {}
        for (const p of rows) {
          expect(p.projectId).toBe('atlas')
          byWeek[p.weekOf] = (byWeek[p.weekOf] ?? 0) + (p.endAt.getTime() - p.startAt.getTime()) / 60_000
        }
        return { rows, byWeek }
      }
      const first = await minutesByWeek()
      expect(first.byWeek).toEqual({ '2026-11-08': 60, '2026-11-15': 120 })
      expect(first.rows[0]).toMatchObject({ startAt: NOW, endAt: new Date('2026-11-09T18:00:00Z'), lane: 0 })
      expect(result.projectPlacements).toHaveLength(first.rows.length)
      expect(result.placements.map((p) => p.taskId).sort()).toEqual(['atlas-task', 'billing-task'])

      // The gym: Monday 15:30, the office morning on Tuesday, then Thursday and Friday afternoon.
      const gym = await db.select().from(routineOccurrences).orderBy(routineOccurrences.startAt)
      expect(gym.slice(0, 4).map((o) => [o.blockId, o.startAt.toISOString(), o.endAt.toISOString()])).toEqual([
        ['gym', '2026-11-09T23:30:00.000Z', '2026-11-10T00:45:00.000Z'],
        ['gym', '2026-11-10T17:00:00.000Z', '2026-11-10T18:15:00.000Z'],
        ['gym', '2026-11-12T23:30:00.000Z', '2026-11-13T00:45:00.000Z'],
        ['gym', '2026-11-13T23:30:00.000Z', '2026-11-14T00:45:00.000Z'],
      ])

      const [summary] = await db.select().from(planSummary)
      expect(summary?.missed).toEqual([])
      expect(summary?.capacity.map((c) => c.date)).toEqual([
        '2026-11-09',
        '2026-11-10',
        '2026-11-11',
        '2026-11-12',
        '2026-11-13',
        '2026-11-14',
        '2026-11-15',
      ])
      // Tuesday is empty: the office block is 09:00–16:20 (440 minutes) less the 75-minute gym.
      expect(summary?.capacity[1]?.freeMinutes).toEqual({ computer: 365, errand: 0, home: 0, office: 365 })
      // Saturday has no block at all.
      expect(summary?.capacity[5]?.freeMinutes).toEqual({ computer: 0, errand: 0, home: 0, office: 0 })

      // 11:30 Monday. The hour of project time is over, so it is this week's time spent: with the
      // task still open, the budget is used up and no more project time is planned this week.
      const later = new Date('2026-11-09T19:30:00Z')
      await runScheduling(db, { HORIZON_DAYS: 28 }, later)
      const second = await minutesByWeek()
      expect(second.byWeek).toEqual({ '2026-11-08': 60, '2026-11-15': 120 })
      expect(second.rows[0]).toEqual(first.rows[0])

      // Two weeks after it ended, the record is dropped.
      await runScheduling(db, { HORIZON_DAYS: 28 }, new Date('2026-11-24T17:00:00Z'))
      expect((await db.select().from(projectPlacements)).map((p) => p.id)).not.toContain(first.rows[0]?.id)
    } finally {
      await close()
    }
  })

  it('moves the office-morning gym to Wednesday when Tuesday is taken, and records the week when both are', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      await db.insert(googleAccounts).values({ id: 'acc', email: 'me@example.com', label: 'work', refreshTokenEnc: 'x' })
      await db.insert(calendars).values({ id: 'cal', accountId: 'acc', googleId: 'me@example.com', summary: 'Work', accessRole: 'owner' })
      const officeMornings = async () => {
        const rows = await db.select().from(routineOccurrences).orderBy(routineOccurrences.startAt)
        // 09:00 Pacific is 17:00Z; the afternoon sessions start at 23:30Z.
        return rows.map((o) => o.startAt.toISOString()).filter((start) => start.endsWith('T17:00:00.000Z') && start < '2026-11-15')
      }

      // A Tuesday 09:30 meeting overlaps the 09:00–10:15 session.
      await db.insert(events).values(eventRow('tue', { startAt: new Date('2026-11-10T17:30:00Z'), endAt: new Date('2026-11-10T18:00:00Z') }))
      await runScheduling(db, { HORIZON_DAYS: 28 }, NOW)
      expect(await officeMornings()).toEqual(['2026-11-11T17:00:00.000Z'])
      expect((await db.select().from(planSummary))[0]?.missed).toEqual([])

      await db.insert(events).values(eventRow('wed', { startAt: new Date('2026-11-11T17:00:00Z'), endAt: new Date('2026-11-11T17:30:00Z') }))
      await runScheduling(db, { HORIZON_DAYS: 28 }, NOW)
      expect(await officeMornings()).toEqual([])
      expect((await db.select().from(planSummary))[0]?.missed).toEqual([{ blockId: 'gym', weekOf: '2026-11-08' }])
    } finally {
      await close()
    }
  })

  it('plans nothing, and no gym, on a day that is marked off', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      await db.insert(tasks).values(taskRow('deep-work', 'inbox'))
      await db.insert(dayOverrides).values({ date: '2026-11-09', kind: 'off' })
      await runScheduling(db, { HORIZON_DAYS: 28 }, NOW)
      // Tuesday at the office, straight after the 09:00–10:15 gym session.
      expect(await db.select({ taskId: placements.taskId, startAt: placements.startAt }).from(placements)).toEqual([
        { taskId: 'deep-work', startAt: new Date('2026-11-10T18:15:00Z') },
      ])
      const gym = await db.select().from(routineOccurrences).orderBy(routineOccurrences.startAt)
      expect(gym[0]?.startAt.toISOString()).toBe('2026-11-10T17:00:00.000Z')

      // A tombstoned override no longer applies: Monday has its gym session again and takes new
      // work. `deep-work` keeps the time it was given, as a plan that still holds always does.
      await db.update(dayOverrides).set({ deletedAt: NOW })
      await db.insert(tasks).values(taskRow('new-work', 'inbox', { createdAt: NOW }))
      await runScheduling(db, { HORIZON_DAYS: 28 }, new Date(NOW.getTime() + 60_000))
      expect(await db.select({ taskId: placements.taskId, startAt: placements.startAt }).from(placements).orderBy(placements.startAt)).toEqual([
        { taskId: 'new-work', startAt: new Date('2026-11-09T17:15:00Z') },
        { taskId: 'deep-work', startAt: new Date('2026-11-10T18:15:00Z') },
      ])
      const restored = await db.select().from(routineOccurrences).orderBy(routineOccurrences.startAt)
      expect(restored[0]?.startAt.toISOString()).toBe('2026-11-09T23:30:00.000Z')
    } finally {
      await close()
    }
  })
})
