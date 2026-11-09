import { describe, expect, it } from 'vitest'
import { schedule } from '../src/index.js'
import type { Interval, Schedule, SchedulerInput, SchedulerResult, Task } from '../src/index.js'

const LA = 'America/Los_Angeles'

/** Mon–Fri 09:00–12:00 and 13:00–17:00 Pacific. */
const WORK: Schedule = {
  id: 'work',
  timeZone: LA,
  windows: [
    { days: [1, 2, 3, 4, 5], start: '09:00', end: '12:00' },
    { days: [1, 2, 3, 4, 5], start: '13:00', end: '17:00' },
  ],
}

/** Monday 2026-11-09 09:00 PST (UTC-8). */
const NOW = '2026-11-09T09:00:00-08:00'

const iso = (s: string): string => new Date(s).toISOString()
const busy = (start: string, end: string): Interval => ({ start, end })

function task(overrides: Partial<Task> & { id: string }): Task {
  return {
    scheduleId: 'work',
    durationMinutes: 60,
    priority: 'medium',
    deadlineType: 'none',
    createdAt: '2026-11-01T00:00:00Z',
    ...overrides,
  }
}

function run(tasks: Task[], busyTime: Interval[] = [], extra: Partial<SchedulerInput> = {}): SchedulerResult {
  return schedule({ now: NOW, schedules: [WORK], tasks, busy: busyTime, ...extra })
}

function spansOf(result: SchedulerResult, taskId: string): [string, string][] {
  return result.placements.filter((p) => p.taskId === taskId).map((p) => [p.start, p.end])
}

const MONDAY_FULL = [busy('2026-11-09T09:00:00-08:00', '2026-11-09T17:00:00-08:00')]

describe('placement basics', () => {
  it('places a task at the first free grid slot inside work hours', () => {
    const result = run([task({ id: 'a' })], [], { now: '2026-11-09T09:07:00-08:00' })
    expect(spansOf(result, 'a')).toEqual([[iso('2026-11-09T09:15:00-08:00'), iso('2026-11-09T10:15:00-08:00')]])
    expect(result.unscheduled).toEqual([])
    expect(result.late).toEqual([])
  })

  it('skips busy calendar time', () => {
    const result = run([task({ id: 'a' })], [busy('2026-11-09T09:00:00-08:00', '2026-11-09T11:00:00-08:00')])
    expect(spansOf(result, 'a')).toEqual([[iso('2026-11-09T11:00:00-08:00'), iso('2026-11-09T12:00:00-08:00')]])
  })

  it('needs one contiguous block when no minimum chunk is set', () => {
    // Morning has only 90 free minutes; a 2h block must wait for the afternoon window.
    const result = run(
      [task({ id: 'a', durationMinutes: 120 })],
      [busy('2026-11-09T09:00:00-08:00', '2026-11-09T10:30:00-08:00')],
    )
    expect(spansOf(result, 'a')).toEqual([[iso('2026-11-09T13:00:00-08:00'), iso('2026-11-09T15:00:00-08:00')]])
  })

  it('respects the start date', () => {
    const result = run([task({ id: 'a', startAt: '2026-11-11T00:00:00-08:00' })])
    expect(spansOf(result, 'a')).toEqual([[iso('2026-11-11T09:00:00-08:00'), iso('2026-11-11T10:00:00-08:00')]])
  })

  it('subtracts completed minutes from the duration', () => {
    const result = run([task({ id: 'a', durationMinutes: 120, completedMinutes: 90 })])
    expect(spansOf(result, 'a')).toEqual([[iso('2026-11-09T09:00:00-08:00'), iso('2026-11-09T09:30:00-08:00')]])
  })

  it('ignores fully completed tasks', () => {
    const result = run([task({ id: 'a', durationMinutes: 60, completedMinutes: 60 })])
    expect(result.placements).toEqual([])
    expect(result.unscheduled).toEqual([])
  })

  it('reports tasks whose schedule is unknown', () => {
    const result = run([task({ id: 'a', scheduleId: 'nope' })])
    expect(result.unscheduled).toEqual([{ taskId: 'a', reason: 'unknown_schedule', unplacedMinutes: 60 }])
  })
})

describe('chunking', () => {
  it('splits across gaps, each piece at least the minimum chunk', () => {
    const result = run(
      [task({ id: 'a', durationMinutes: 180, minChunkMinutes: 60 })],
      [busy('2026-11-09T09:00:00-08:00', '2026-11-09T10:30:00-08:00')],
    )
    expect(spansOf(result, 'a')).toEqual([
      [iso('2026-11-09T10:30:00-08:00'), iso('2026-11-09T12:00:00-08:00')],
      [iso('2026-11-09T13:00:00-08:00'), iso('2026-11-09T14:30:00-08:00')],
    ])
  })

  it('skips gaps shorter than the minimum chunk', () => {
    const result = run(
      [task({ id: 'a', durationMinutes: 180, minChunkMinutes: 60 })],
      [
        busy('2026-11-09T09:00:00-08:00', '2026-11-09T10:30:00-08:00'),
        busy('2026-11-09T11:15:00-08:00', '2026-11-09T12:00:00-08:00'),
      ],
    )
    // The 45-minute 10:30–11:15 gap is skipped.
    expect(spansOf(result, 'a')).toEqual([[iso('2026-11-09T13:00:00-08:00'), iso('2026-11-09T16:00:00-08:00')]])
  })

  it('places a final remainder shorter than the minimum chunk', () => {
    const result = run(
      [task({ id: 'a', durationMinutes: 100, minChunkMinutes: 60 })],
      [busy('2026-11-09T09:00:00-08:00', '2026-11-09T11:00:00-08:00')],
    )
    expect(spansOf(result, 'a')).toEqual([
      [iso('2026-11-09T11:00:00-08:00'), iso('2026-11-09T12:00:00-08:00')],
      [iso('2026-11-09T13:00:00-08:00'), iso('2026-11-09T13:40:00-08:00')],
    ])
  })
})

describe('ordering', () => {
  it('goes ASAP first, then earliest due day, then priority', () => {
    const result = run([
      task({ id: 'fri-low', priority: 'low', deadlineType: 'soft', dueAt: '2026-11-13T17:00:00-08:00' }),
      task({ id: 'tue-high', priority: 'high', deadlineType: 'soft', dueAt: '2026-11-10T17:00:00-08:00' }),
      task({ id: 'asap', priority: 'asap' }),
      task({ id: 'tue-low', priority: 'low', deadlineType: 'soft', dueAt: '2026-11-10T17:00:00-08:00' }),
    ])
    const order = result.placements.map((p) => p.taskId)
    expect(order).toEqual(['asap', 'tue-high', 'tue-low', 'fri-low'])
    expect(result.placements.map((p) => p.start)).toEqual([
      iso('2026-11-09T09:00:00-08:00'),
      iso('2026-11-09T10:00:00-08:00'),
      iso('2026-11-09T11:00:00-08:00'),
      iso('2026-11-09T13:00:00-08:00'),
    ])
  })

  it('puts a hard deadline before a soft one due the same day, regardless of priority', () => {
    const result = run([
      task({ id: 'soft-high', priority: 'high', deadlineType: 'soft', dueAt: '2026-11-10T17:00:00-08:00' }),
      task({ id: 'hard-low', priority: 'low', deadlineType: 'hard', dueAt: '2026-11-10T12:00:00-08:00' }),
    ])
    expect(result.placements.map((p) => p.taskId)).toEqual(['hard-low', 'soft-high'])
  })

  it('treats a due date as absent when deadlineType is none', () => {
    const result = run([
      task({ id: 'none-with-date', priority: 'high', deadlineType: 'none', dueAt: '2026-11-09T12:00:00-08:00' }),
      task({ id: 'soft-later', priority: 'low', deadlineType: 'soft', dueAt: '2026-11-20T12:00:00-08:00' }),
    ])
    expect(result.placements.map((p) => p.taskId)).toEqual(['soft-later', 'none-with-date'])
  })

  it('is deterministic regardless of input order', () => {
    const tasks = [
      task({ id: 'a', priority: 'low' }),
      task({ id: 'b', priority: 'high', deadlineType: 'soft', dueAt: '2026-11-12T17:00:00-08:00' }),
      task({ id: 'c', priority: 'asap', durationMinutes: 30 }),
      task({ id: 'd', priority: 'medium', durationMinutes: 240, minChunkMinutes: 60 }),
      task({ id: 'e', priority: 'medium', createdAt: '2026-10-01T00:00:00Z' }),
      task({ id: 'f', pinnedStart: '2026-11-09T14:00:00-08:00' }),
    ]
    const forward = run(tasks, MONDAY_FULL.slice(0, 0))
    const reversed = run([...tasks].reverse())
    expect(reversed).toEqual(forward)
    // Earlier-created wins the tie between two otherwise identical tasks.
    const eStart = forward.placements.find((p) => p.taskId === 'e')?.start ?? ''
    const aStart = forward.placements.find((p) => p.taskId === 'a')?.start ?? ''
    expect(eStart < aStart).toBe(true)
  })
})

describe('deadlines', () => {
  it('spills a hard deadline into the evening overflow window when work hours are full', () => {
    const result = run(
      [task({ id: 'a', deadlineType: 'hard', dueAt: '2026-11-09T23:59:00-08:00' })],
      MONDAY_FULL,
    )
    expect(spansOf(result, 'a')).toEqual([[iso('2026-11-09T17:00:00-08:00'), iso('2026-11-09T18:00:00-08:00')]])
    expect(result.unscheduled).toEqual([])
    expect(result.late).toEqual([])
  })

  it('never places a hard-deadline task past its deadline', () => {
    // 09:00–10:00 is free but the task needs two contiguous hours before 10:00.
    const result = run([task({ id: 'a', durationMinutes: 120, deadlineType: 'hard', dueAt: '2026-11-09T10:00:00-08:00' })])
    expect(result.placements).toEqual([])
    expect(result.unscheduled).toEqual([{ taskId: 'a', reason: 'no_fit_before_hard_deadline', unplacedMinutes: 120 }])
  })

  it('keeps partial placements of a chunkable hard-deadline task and reports the rest', () => {
    const result = run([
      task({ id: 'a', durationMinutes: 120, minChunkMinutes: 30, deadlineType: 'hard', dueAt: '2026-11-09T10:00:00-08:00' }),
    ])
    expect(spansOf(result, 'a')).toEqual([[iso('2026-11-09T09:00:00-08:00'), iso('2026-11-09T10:00:00-08:00')]])
    expect(result.unscheduled).toEqual([{ taskId: 'a', reason: 'no_fit_before_hard_deadline', unplacedMinutes: 60 }])
  })

  it('places a soft deadline that cannot be met and reports it late', () => {
    const result = run(
      [task({ id: 'a', deadlineType: 'soft', dueAt: '2026-11-09T23:59:00-08:00' })],
      MONDAY_FULL,
    )
    expect(spansOf(result, 'a')).toEqual([[iso('2026-11-10T09:00:00-08:00'), iso('2026-11-10T10:00:00-08:00')]])
    expect(result.late).toEqual([{ taskId: 'a', dueAt: '2026-11-09T23:59:00-08:00', eta: iso('2026-11-10T10:00:00-08:00') }])
    expect(result.unscheduled).toEqual([])
  })

  it('does not report a met soft deadline as late', () => {
    const result = run([task({ id: 'a', deadlineType: 'soft', dueAt: '2026-11-09T12:00:00-08:00' })])
    expect(result.late).toEqual([])
  })
})

describe('pinned tasks', () => {
  it('stay where they are and block other tasks', () => {
    const result = run([
      task({ id: 'flex' }),
      task({ id: 'pinned', pinnedStart: '2026-11-09T09:00:00-08:00' }),
    ])
    expect(result.placements).toEqual([
      { taskId: 'pinned', start: iso('2026-11-09T09:00:00-08:00'), end: iso('2026-11-09T10:00:00-08:00'), pinned: true },
      { taskId: 'flex', start: iso('2026-11-09T10:00:00-08:00'), end: iso('2026-11-09T11:00:00-08:00'), pinned: false },
    ])
  })
})

describe('horizon', () => {
  it('reports what does not fit in the horizon and keeps partial placements', () => {
    // Horizon of one day: Monday has 7 free hours; a 10h task leaves 3h unplaced.
    const result = run([task({ id: 'a', durationMinutes: 600, minChunkMinutes: 60 })], [], { horizonDays: 1 })
    expect(spansOf(result, 'a')).toEqual([
      [iso('2026-11-09T09:00:00-08:00'), iso('2026-11-09T12:00:00-08:00')],
      [iso('2026-11-09T13:00:00-08:00'), iso('2026-11-09T17:00:00-08:00')],
    ])
    expect(result.unscheduled).toEqual([{ taskId: 'a', reason: 'no_fit_in_horizon', unplacedMinutes: 180 }])
  })
})

describe('time zones', () => {
  it('follows the schedule across the fall-back DST change', () => {
    const fridayPdt = '2026-10-30T08:00:00-07:00'
    const sameDay = run([task({ id: 'a' })], [], { now: fridayPdt })
    expect(spansOf(sameDay, 'a')).toEqual([['2026-10-30T16:00:00.000Z', '2026-10-30T17:00:00.000Z']])

    const fridayFull = [busy('2026-10-30T09:00:00-07:00', '2026-10-30T17:00:00-07:00')]
    const nextWeek = run([task({ id: 'a' })], fridayFull, { now: fridayPdt })
    // Monday 2026-11-02 09:00 is PST (UTC-8), so 17:00Z rather than 16:00Z.
    expect(spansOf(nextWeek, 'a')).toEqual([['2026-11-02T17:00:00.000Z', '2026-11-02T18:00:00.000Z']])
  })
})

describe('plan stability', () => {
  const at = (time: string): string => iso(`2026-11-09T${time}:00-08:00`)
  const block = (taskId: string, start: string, end: string) => ({
    taskId, start: at(start), end: at(end), pinned: false,
  })

  it('reuses the first run unchanged, including split blocks and tomorrow', () => {
    const tasks = [
      task({ id: 'a', durationMinutes: 480, minChunkMinutes: 60 }),
      task({ id: 'b', priority: 'low' }),
    ]
    const first = run(tasks)
    expect(first.placements).toEqual([
      block('a', '09:00', '12:00'),
      block('a', '13:00', '17:00'),
      { taskId: 'a', start: iso('2026-11-10T09:00:00-08:00'), end: iso('2026-11-10T10:00:00-08:00'), pinned: false },
      { taskId: 'b', start: iso('2026-11-10T10:00:00-08:00'), end: iso('2026-11-10T11:00:00-08:00'), pinned: false },
    ])
    expect(run(tasks, [], { previous: first.placements })).toEqual(first)
  })

  it('keeps an in-progress block through successive runs, ahead of new ASAP work', () => {
    const a = task({ id: 'a' })
    const first = run([a])
    const ten = run([a], [], { now: at('09:10'), previous: first.placements })
    expect(ten.placements).toEqual([block('a', '09:00', '10:00')])
    const forty = run([a, task({ id: 'urgent', priority: 'asap' })], [], {
      now: at('09:40'), previous: ten.placements,
    })
    expect(forty.placements).toEqual([
      block('a', '09:00', '10:00'), block('urgent', '10:00', '11:00'),
    ])
  })

  it.each([
    [30, '09:30'],
    [50, '09:20'], // Only ten minutes remain, but the retained end cannot precede now.
  ])('trims active work with %i completed minutes, never before now', (completedMinutes, end) => {
    const result = run([task({ id: 'a', completedMinutes })], [], {
      now: at('09:20'), previous: [block('a', '09:00', '10:00')],
    })
    expect(result.placements).toEqual([block('a', '09:00', end)])
    expect(result.unscheduled).toEqual([])
  })

  it('frees completed and removed tasks, and ignores elapsed blocks', () => {
    const result = run([task({ id: 'done', completedMinutes: 60 }), task({ id: 'new' })], [], {
      now: at('10:00'),
      previous: [block('done', '09:30', '10:30'), block('removed', '10:00', '11:00'), block('new', '09:00', '10:00')],
    })
    expect(result.placements).toEqual([block('new', '10:00', '11:00')])
  })

  it('counts the full active block and places only the remainder after it', () => {
    const result = run([task({ id: 'a', durationMinutes: 90 })], [], {
      now: at('09:40'), previous: [block('a', '09:00', '10:00')],
    })
    expect(result.placements).toEqual([block('a', '09:00', '10:00'), block('a', '10:00', '10:30')])
  })

  it('does not move existing blocks to pack in a new low-priority task', () => {
    const result = run([task({ id: 'a' }), task({ id: 'b' }), task({ id: 'new', priority: 'low' })], [], {
      previous: [block('a', '11:00', '12:00'), block('b', '13:00', '14:00')],
    })
    expect(result.placements).toEqual([
      block('new', '09:00', '10:00'), block('a', '11:00', '12:00'), block('b', '13:00', '14:00'),
    ])
  })

  it('lets new ASAP work take the earliest slot, moving only the displaced block', () => {
    const result = run([task({ id: 'a' }), task({ id: 'b' }), task({ id: 'urgent', priority: 'asap' })], [], {
      now: at('08:00'), previous: [block('a', '09:00', '10:00'), block('b', '11:00', '12:00')],
    })
    expect(result.placements).toEqual([
      block('urgent', '09:00', '10:00'), block('a', '10:00', '11:00'), block('b', '11:00', '12:00'),
    ])
  })

  it('allows displacement to cascade in task order when lower-priority blocks are tightly packed', () => {
    const result = run([task({ id: 'a' }), task({ id: 'b' }), task({ id: 'urgent', priority: 'asap' })], [], {
      now: at('08:00'), previous: [block('a', '09:00', '10:00'), block('b', '10:00', '11:00')],
    })
    expect(result.placements).toEqual([
      block('urgent', '09:00', '10:00'), block('a', '10:00', '11:00'), block('b', '11:00', '12:00'),
    ])
  })

  it('drops a future block that overlaps new busy time instead of keeping a fragment', () => {
    const result = run([task({ id: 'a' })], [busy(at('09:30'), at('10:00'))], {
      now: at('08:00'), previous: [block('a', '09:00', '10:00')],
    })
    expect(result.placements).toEqual([block('a', '10:00', '11:00')])
  })

  it('drops blocks outside a changed schedule window', () => {
    const result = run([task({ id: 'a' })], [], {
      now: at('08:00'),
      previous: [block('a', '09:00', '10:00')],
      schedules: [{ ...WORK, windows: [{ days: [1], start: '11:00', end: '12:00' }] }],
    })
    expect(result.placements).toEqual([block('a', '11:00', '12:00')])
  })

  it('drops a future block before a changed start date', () => {
    const result = run([task({ id: 'a', startAt: at('10:15') })], [], {
      previous: [block('a', '10:00', '11:00')],
    })
    expect(result.placements).toEqual([block('a', '10:15', '11:15')])
  })

  it('drops a future block past a hard deadline but reuses a late soft-deadline block', () => {
    const result = run([
      task({ id: 'hard', deadlineType: 'hard', dueAt: at('10:00') }),
      task({ id: 'soft', deadlineType: 'soft', dueAt: at('10:00') }),
    ], [], { previous: [block('hard', '10:00', '11:00'), block('soft', '11:00', '12:00')] })
    expect(result.placements).toEqual([block('hard', '09:00', '10:00'), block('soft', '11:00', '12:00')])
    expect(result.late).toEqual([{ taskId: 'soft', dueAt: at('10:00'), eta: at('12:00') }])
  })

  it('does not retain future blocks beyond the horizon', () => {
    const result = run([task({ id: 'a' })], [], {
      horizonDays: 1,
      previous: [{ taskId: 'a', start: iso('2026-11-10T10:00:00-08:00'), end: iso('2026-11-10T11:00:00-08:00'), pinned: false }],
    })
    expect(result.placements).toEqual([block('a', '09:00', '10:00')])
  })

  it('retains only whole future blocks when completed minutes shorten the task', () => {
    const result = run([task({ id: 'a', durationMinutes: 120, completedMinutes: 30, minChunkMinutes: 30 })], [], {
      previous: [block('a', '10:00', '11:00'), block('a', '13:00', '14:00')],
    })
    expect(result.placements).toEqual([block('a', '09:00', '09:30'), block('a', '10:00', '11:00')])
  })

  it('cuts active work at the first upcoming busy interval and reschedules the remainder', () => {
    const result = run([task({ id: 'a' })], [
      busy(at('09:45'), at('10:00')), busy(at('09:30'), at('09:40')),
    ], {
      now: at('09:10'), previous: [block('a', '09:00', '10:00')],
    })
    // Keep 30 minutes of the original hour. Neither gap before 10:00 fits the remaining 30.
    expect(result.placements).toEqual([block('a', '09:00', '09:30'), block('a', '10:00', '10:30')])
    expect(result.unscheduled).toEqual([])
  })

  it('preserves active work despite already-started busy time or a changed schedule and start date', () => {
    const result = run([task({ id: 'a', startAt: at('13:00') })], [busy(at('09:30'), at('10:30'))], {
      now: at('09:40'), previous: [block('a', '09:00', '10:00')],
      schedules: [{ ...WORK, windows: [] }],
    })
    expect(result.placements).toEqual([block('a', '09:00', '10:00')])
    expect(result.unscheduled).toEqual([])
  })

  it('keeps active work even if its schedule disappeared, reporting only the unplaced remainder', () => {
    const result = run([task({ id: 'a', scheduleId: 'missing', durationMinutes: 90 })], [], {
      now: at('09:40'), previous: [block('a', '09:00', '10:00')],
    })
    expect(result.placements).toEqual([block('a', '09:00', '10:00')])
    expect(result.unscheduled).toEqual([{ taskId: 'a', reason: 'unknown_schedule', unplacedMinutes: 30 }])
  })

  it('keeps active work past a changed hard deadline and reports its retained ETA', () => {
    const result = run([task({ id: 'a', deadlineType: 'hard', dueAt: at('09:30') })], [], {
      now: at('09:40'), previous: [block('a', '09:00', '10:00')],
    })
    expect(result.placements).toEqual([block('a', '09:00', '10:00')])
    expect(result.unscheduled).toEqual([])
    expect(result.late).toEqual([{ taskId: 'a', dueAt: at('09:30'), eta: at('10:00') }])
  })

  it('leaves pinned behavior unchanged and ignores stale previous blocks for pinned tasks', () => {
    const tasks = [
      task({ id: 'pinned', pinnedStart: at('08:00'), completedMinutes: 30 }),
      task({ id: 'flex' }),
    ]
    const result = run(tasks, [], {
      previous: [block('pinned', '09:00', '10:00'), block('flex', '08:00', '09:00')],
    })
    expect(result).toEqual(run(tasks))
    expect(result.placements).toEqual([
      { ...block('pinned', '08:00', '08:30'), pinned: true }, block('flex', '09:00', '10:00'),
    ])
  })
})

describe('input validation', () => {
  it('rejects unparsable instants', () => {
    expect(() => run([task({ id: 'a', dueAt: 'tomorrow', deadlineType: 'soft' })])).toThrow(/dueAt/)
    expect(() => schedule({ now: 'nope', schedules: [], tasks: [], busy: [] })).toThrow(/now/)
  })
})
