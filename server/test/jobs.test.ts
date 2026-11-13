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
})
