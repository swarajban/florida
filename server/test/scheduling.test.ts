import { describe, expect, it } from 'vitest'
import type { EventRow, ProjectRow, ScheduleRow, TaskRow } from '../src/db/schema.js'
import { buildSchedulerInput } from '../src/scheduling.js'

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

function projectRow(id: string, scheduleId: string, over: Partial<ProjectRow> = {}): ProjectRow {
  return { id, name: id, color: null, scheduleId, sortOrder: 0, createdAt: T0, updatedAt: T0, deletedAt: null, ...over }
}

function taskRow(id: string, projectId: string, over: Partial<TaskRow> = {}): TaskRow {
  return {
    id,
    projectId,
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
      projects: [projectRow('inbox', 'work')],
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

  it("falls back to the project's schedule and lets the task override win", () => {
    const input = buildSchedulerInput({
      ...base,
      projects: [projectRow('inbox', 'work')],
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
      projects: [projectRow('inbox', 'work'), projectRow('archived', 'work', { deletedAt: NOW })],
      tasks: [
        taskRow('open', 'inbox'),
        taskRow('deleted', 'inbox', { deletedAt: NOW }),
        taskRow('done', 'inbox', { completedAt: NOW }),
        taskRow('orphan', 'archived'),
        taskRow('no-project', 'missing'),
      ],
      events: [],
    })
    expect(input.schedules.map((s) => s.id)).toEqual(['work'])
    expect(input.tasks.map((t) => t.id)).toEqual(['open'])
  })

  it('turns only live, timed, opaque, not-declined events inside the horizon into busy time', () => {
    const input = buildSchedulerInput({
      ...base,
      projects: [],
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
