import { afterEach, describe, expect, it, vi } from 'vitest'
import type { Db } from '../src/db/client.js'

const cursor = '2026-11-13T14:00:00.000Z'
const database = (lagMs: number) => ({
  select: () => ({ from: () => ({ where: async () => [{ cursor, lagMs }] }) }),
}) as unknown as Db

afterEach(() => {
  vi.restoreAllMocks()
  vi.resetModules()
})

describe('cursor fence observability', () => {
  it('returns the fenced cursor without warning for a short transaction', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { syncCursor } = await import('../src/db/sync-clock.js')
    expect(await syncCursor(database(59_999))).toEqual(new Date(cursor))
    expect(warn).not.toHaveBeenCalled()
  })

  it('warns for an old open transaction without advancing the cursor or flooding logs', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const clock = vi.spyOn(performance, 'now').mockReturnValue(0)
    const { syncCursor } = await import('../src/db/sync-clock.js')
    expect(await syncCursor(database(60_000))).toEqual(new Date(cursor))
    expect(warn).toHaveBeenCalledExactlyOnceWith(`[sync] an open transaction is holding the cursor back by 60000ms; cursor=${cursor}`)
    clock.mockReturnValue(59_999)
    await syncCursor(database(180_000))
    expect(warn).toHaveBeenCalledTimes(1)
    clock.mockReturnValue(60_000)
    expect(await syncCursor(database(180_000))).toEqual(new Date(cursor))
    expect(warn).toHaveBeenCalledTimes(2)
  })
})
