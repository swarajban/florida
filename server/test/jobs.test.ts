import { describe, expect, it, vi } from 'vitest'
import { startJobs } from '../src/jobs.js'

describe('automatic judgment background job', () => {
  it('backfills at startup before Google work and again after sync before rescheduling', async () => {
    vi.useFakeTimers()
    const calls: string[] = []
    const stop = startJobs({
      sync: {
        ensureAllWatches: async () => { calls.push('watches') },
        syncAll: async () => { calls.push('sync') },
      },
      refreshAllDayJudgments: async () => { calls.push('backfill') },
      reschedule: async () => {
        calls.push('reschedule')
        return { placements: [], unscheduled: [], optional: [], routine: [], missed: [], capacity: [] }
      },
    })
    try {
      expect(calls).toEqual([])
      await vi.advanceTimersByTimeAsync(5000)
      expect(calls).toEqual(['backfill', 'reschedule', 'watches', 'sync', 'backfill', 'reschedule'])
    } finally {
      stop()
      vi.useRealTimers()
    }
  })

  it('repairs old cursors only at startup before refresh and publication', async () => {
    vi.useFakeTimers()
    const calls: string[] = []
    const stop = startJobs({
      sync: {
        ensureAllWatches: async () => { calls.push('watches') },
        syncAll: async () => { calls.push('sync') },
      },
      repairJudgmentCursors: async () => { calls.push('repair') },
      refreshAllDayJudgments: async () => { calls.push('refresh') },
      changes: { publish: () => { calls.push('publish') } },
      reschedule: async () => {
        calls.push('reschedule')
        return { placements: [], unscheduled: [], optional: [], routine: [], missed: [], capacity: [] }
      },
    })
    try {
      await vi.advanceTimersByTimeAsync(5000)
      expect(calls).toEqual(['repair', 'refresh', 'reschedule', 'publish', 'watches', 'sync', 'refresh', 'reschedule', 'publish'])
      await vi.advanceTimersByTimeAsync(60 * 60_000)
      expect(calls.filter((call) => call === 'repair')).toHaveLength(1)
      expect(calls.filter((call) => call === 'sync')).toHaveLength(2)
    } finally {
      stop()
      vi.useRealTimers()
    }
  })
})
