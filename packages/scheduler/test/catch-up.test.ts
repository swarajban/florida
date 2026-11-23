import { describe, expect, it } from 'vitest'
import { schedule } from '../src/index.js'
import type { CatchUpBlock, SchedulerInput } from '../src/index.js'

const settings = { enabled: true, minutes: 30, windows: [{ days: [0, 1, 2, 3, 4, 5, 6], start: '18:00', end: '21:00' }] }
const base = {
  now: '2026-11-22T17:00:00-08:00', horizonDays: 2,
  routine: { timeZone: 'America/Los_Angeles', blocks: [] }, busy: [], tasks: [],
} satisfies SchedulerInput
const article = (id: string, estMinutes: number) => ({ id, title: id, estMinutes, site: 'example.com', url: 'https://example.com/story' })
const plan = (queue: ReturnType<typeof article>[], changes: Partial<SchedulerInput> = {}, previous: CatchUpBlock[] = []) =>
  schedule({ ...base, catchUp: { settings, queue, previous }, ...changes }).catchUpBlocks ?? []

describe('Catch up', () => {
  it('does not create an empty block and honors disabled days', () => {
    expect(plan([])).toEqual([])
    const queue = [article('story', 6)]
    expect(plan(queue, { catchUp: { settings: { ...settings, enabled: false }, queue } })).toEqual([])
    const weekends = { ...settings, windows: [{ days: [0, 6], start: '19:00', end: '20:00' }] }
    expect(plan(queue, { catchUp: { settings: weekends, queue } }).map((block) => block.id)).toEqual(['2026-11-22'])
  })

  it('shrinks to the estimate total, with a ten-minute floor and one block per local day', () => {
    const start = '2026-11-23T02:00:00.000Z'
    expect(plan([article('old', 3), article('new', 4)])[0]).toEqual({
      id: '2026-11-22', startAt: start, endAt: '2026-11-23T02:10:00.000Z',
      items: [article('old', 3), article('new', 4)],
    })
    expect(plan([article('short', 17)]).map((block) => [block.id, block.endAt])).toEqual([
      ['2026-11-22', '2026-11-23T02:17:00.000Z'], ['2026-11-23', '2026-11-24T02:17:00.000Z'],
    ])
  })

  it('moves around events and skips an evening without a contiguous slot', () => {
    const busy = [
      { start: '2026-11-22T17:45:00-08:00', end: '2026-11-22T19:00:00-08:00' },
      { start: '2026-11-23T18:20:00-08:00', end: '2026-11-23T21:00:00-08:00' },
    ]
    const queue = [article('old', 18), article('long', 31), article('new', 10)]
    expect(plan(queue, { busy })).toEqual([{
      id: '2026-11-22', startAt: '2026-11-23T03:00:00.000Z', endAt: '2026-11-23T03:30:00.000Z',
      items: [queue[0], queue[2]],
    }])
  })

  it('allows per-day length overrides and does not keep sliding the same block later', () => {
    const queue = [article('old', 12), article('new', 18)]
    const prior = plan(queue)
    expect(plan(queue, { now: '2026-11-22T18:15:00-08:00' }, prior)[0]).toEqual(prior[0])
    expect(plan(queue, { now: '2026-11-22T18:31:00-08:00' }, prior)[0]).toEqual(prior[0])
    const special = { ...settings, windows: [{ days: [0], start: '19:00', end: '20:00', minutes: 15 }] }
    expect(plan(queue, { catchUp: { settings: special, queue } })[0]).toMatchObject({
      startAt: '2026-11-23T03:00:00.000Z', endAt: '2026-11-23T03:15:00.000Z', items: [queue[0]],
    })
  })
})
