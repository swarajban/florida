import { describe, expect, it } from 'vitest'
import { findFreeSlots } from '../src/index.js'
import type { Routine } from '../src/index.js'

const routine: Routine = { timeZone: 'America/Los_Angeles', blocks: [
  { id: 'work', days: [1], start: '09:00', end: '17:00', allows: ['computer', 'office'] },
  { id: 'overlap', days: [1], start: '10:00', end: '12:00', allows: ['computer'] },
  { id: 'gym', days: [1], start: '12:00', end: '13:00', allows: [] },
  { id: 'evening', days: [1], start: '17:00', end: '20:00', allows: ['computer'], optional: true },
] }
const input = { start: '2026-11-09T16:30:00Z', end: '2026-11-10T04:00:00Z', durationMinutes: 60, context: 'computer' as const, routine, busy: [] }

describe('findFreeSlots', () => {
  it('merges windows and subtracts commitments, events and all planned lanes', () => {
    expect(findFreeSlots({ ...input,
      busy: [{ start: '2026-11-09T18:00:00Z', end: '2026-11-09T19:00:00Z' }],
      occupied: [{ start: '2026-11-09T22:00:00Z', end: '2026-11-09T23:30:00Z' }],
    })).toEqual([
      { start: '2026-11-09T17:00:00.000Z', end: '2026-11-09T18:00:00.000Z' },
      { start: '2026-11-09T19:00:00.000Z', end: '2026-11-09T20:00:00.000Z' },
      { start: '2026-11-09T21:00:00.000Z', end: '2026-11-09T22:00:00.000Z' },
      { start: '2026-11-09T23:30:00.000Z', end: '2026-11-10T01:00:00.000Z' },
    ])
  })
  it('clips bounds, filters short windows, context and off-day overrides', () => {
    expect(findFreeSlots({ ...input, start: '2026-11-09T19:30:00Z', end: '2026-11-09T22:00:00Z' })).toEqual([
      { start: '2026-11-09T21:00:00.000Z', end: '2026-11-09T22:00:00.000Z' },
    ])
    expect(findFreeSlots({ ...input, context: 'home' })).toEqual([])
    expect(findFreeSlots({ ...input, dayOverrides: [{ date: '2026-11-09', kind: 'off' }] })).toEqual([])
  })
  it('uses wall time across DST and home-day remapping', () => {
    const blocks: Routine = { timeZone: routine.timeZone, blocks: [{ id: 'home', days: [0], start: '00:00', end: '04:00', allows: ['home'] }] }
    expect(findFreeSlots({ ...input, start: '2026-11-01T07:00:00Z', end: '2026-11-01T13:00:00Z', context: 'home', routine: blocks })).toEqual([
      { start: '2026-11-01T07:00:00.000Z', end: '2026-11-01T12:00:00.000Z' },
    ])
    expect(findFreeSlots({ ...input, start: '2026-11-10T08:00:00Z', end: '2026-11-10T12:00:00Z', context: 'home', routine: blocks, dayOverrides: [{ date: '2026-11-10', kind: 'home' }] })).toEqual([
      { start: '2026-11-10T08:00:00.000Z', end: '2026-11-10T12:00:00.000Z' },
    ])
  })
  it('rejects invalid and unbounded queries', () => {
    for (const patch of [{ end: input.start }, { start: 'invalid' }, { durationMinutes: 0 }, { end: '2027-01-01T00:00:00Z' }]) {
      expect(() => findFreeSlots({ ...input, ...patch })).toThrow(RangeError)
    }
  })

  it('uses settled commitments rather than moving an alternate over the current plan', () => {
    const alternate: Routine = { timeZone: routine.timeZone, blocks: [routine.blocks[0]!, { id: 'gym', days: [], start: '12:00', end: '13:00', allows: [], alternates: [{ day: 1, start: '10:00', end: '11:00' }, { day: 1, start: '14:00', end: '15:00' }] }] }
    expect(findFreeSlots({ ...input, routine: alternate,
      occupied: [{ start: '2026-11-09T18:00:00Z', end: '2026-11-09T19:00:00Z' }],
      commitments: [{ start: '2026-11-09T22:00:00Z', end: '2026-11-09T23:00:00Z' }],
    })).toEqual([
      { start: '2026-11-09T17:00:00.000Z', end: '2026-11-09T18:00:00.000Z' },
      { start: '2026-11-09T19:00:00.000Z', end: '2026-11-09T22:00:00.000Z' },
      { start: '2026-11-09T23:00:00.000Z', end: '2026-11-10T01:00:00.000Z' },
    ])
  })

  it('keeps settled commitments when the query crosses their stored horizon', () => {
    const alternate: Routine = { timeZone: routine.timeZone, blocks: [routine.blocks[0]!, { id: 'gym', days: [], start: '12:00', end: '13:00', allows: [], alternates: [{ day: 1, start: '10:00', end: '11:00' }, { day: 1, start: '14:00', end: '15:00' }] }] }
    const slots = findFreeSlots({ ...input, routine: alternate, end: '2026-11-24T02:00:00Z',
      occupied: [{ start: '2026-11-09T18:00:00Z', end: '2026-11-09T19:00:00Z' }],
      commitments: [{ start: '2026-11-09T22:00:00Z', end: '2026-11-09T23:00:00Z' }],
      commitmentWindow: { start: input.start, end: '2026-11-16T17:00:00Z' },
    })
    expect(slots.some((p) => Date.parse(p.start) < Date.parse('2026-11-09T23:00:00Z') && Date.parse(p.end) > Date.parse('2026-11-09T22:00:00Z'))).toBe(false)
    expect(slots.some((p) => Date.parse(p.start) < Date.parse('2026-11-23T19:00:00Z') && Date.parse(p.end) > Date.parse('2026-11-23T18:00:00Z'))).toBe(false)
  })

  it('allows any nonoptional work context when none is requested', () => {
    const { context, ...anyContext } = input
    expect(findFreeSlots({ ...anyContext, routine: { ...routine, blocks: [{ id: 'errand', days: [1], start: '09:00', end: '10:00', allows: ['errand'] }] } })).toHaveLength(1)
    expect(findFreeSlots({ ...input, routine: { ...routine, blocks: [{ id: 'errand', days: [1], start: '09:00', end: '10:00', allows: ['errand'] }] } })).toEqual([])
  })
})
