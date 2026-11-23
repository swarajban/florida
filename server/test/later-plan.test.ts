import { expect, it } from 'vitest'
import { createApp } from '../src/app.js'
import { saveLater, setLaterState } from '../src/later.js'
import { runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { createTestDb } from './db.js'
import { FakeSync, testConfig } from './fixtures.js'

it('publishes the same oldest-first Catch up block in sync and get_range', async () => {
  const { db, close } = await createTestDb()
  let now = new Date('2026-11-22T16:00:00-08:00')
  const config = { ...testConfig, HORIZON_DAYS: 2 }
  const reschedule = () => runScheduling(db, config, now)
  try {
    await seed(db)
    for (const [id, savedAt] of [['new', '2026-11-22'], ['old', '2026-11-21'], ['read', '2026-11-20'], ['archived', '2026-11-19']] as const) {
      await saveLater(db, id, { url: `https://example.com/${id}`, source: 'manual', savedAt: `${savedAt}T00:00:00Z` })
    }
    await setLaterState(db, 'read', { action: 'read' })
    await setLaterState(db, 'archived', { action: 'archive' })
    const app = createApp({ db, config, reschedule, sync: new FakeSync() })
    const headers = { authorization: `Bearer ${config.API_TOKEN}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream' }
    const preferences = { enabled: true, minutes: 25, windows: [{ days: [0], start: '18:00', end: '20:00' }] }
    const updateSettings = (body: object) =>
      app.request('/api/settings', { method: 'PUT', headers, body: JSON.stringify({ timeZone: 'America/Los_Angeles', ...body }) })
    expect((await updateSettings({ catchUp: { ...preferences, windows: [...preferences.windows, ...preferences.windows] } })).status).toBe(400)
    expect((await updateSettings({ catchUp: preferences })).status).toBe(200)
    expect((await updateSettings({})).status).toBe(200)
    const response = await (await app.request('/api/sync?since=2026-11-22T00:00:00Z', { headers })).json()
    expect(response.settings.catchUp).toEqual(preferences)
    expect(response.catchUpBlocks).toEqual([{
      id: '2026-11-22', startAt: '2026-11-23T02:00:00.000Z', endAt: '2026-11-23T02:10:00.000Z',
      items: ['old', 'new'].map((id) => ({ id, title: 'example.com', site: 'example.com', url: `https://example.com/${id}`, estMinutes: 5 })),
    }])
    const getRange = async () => (await app.request('/mcp', { method: 'POST', headers, body: JSON.stringify({
      jsonrpc: '2.0', id: 1, method: 'tools/call',
      params: { name: 'get_range', arguments: { startDate: '2026-11-22', endDate: '2026-11-23' } },
    }) })).json().then(({ result }) => result.structuredContent.days.map((day: { catchUpBlocks: unknown[] }) => day.catchUpBlocks))
    expect(await getRange()).toEqual([response.catchUpBlocks, []])
    now = new Date('2026-11-22T18:11:00-08:00')
    await setLaterState(db, 'new', { action: 'read' })
    await setLaterState(db, 'old', { action: 'read' })
    expect((await reschedule()).catchUpBlocks).toBeUndefined()
    expect((await (await app.request('/api/sync', { headers })).json()).catchUpBlocks).toEqual([])
    expect(await getRange()).toEqual([[], []])
  } finally {
    await close()
  }
})

it.each([false, true])('publishes a full block for a long unread item (short items: %s)', async (withShorts) => {
  const { db, close } = await createTestDb()
  const now = new Date('2026-11-23T16:00:00-08:00')
  const config = { ...testConfig, HORIZON_DAYS: 3 }
  const reschedule = () => runScheduling(db, config, now)
  try {
    await seed(db)
    const entries: [string, number, string][] = [['long', 44, '19']]
    if (withShorts) entries.push(['new', 10, '21'], ['old', 18, '20'])
    for (const [id, estMinutes, day] of entries) {
      await saveLater(db, id, {
        url: `https://example.com/${id}`, source: 'manual', savedAt: `2026-11-${day}T00:00:00Z`, estMinutes,
      })
    }
    const app = createApp({ db, config, reschedule, sync: new FakeSync() })
    const headers = { authorization: `Bearer ${config.API_TOKEN}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream' }
    expect((await app.request('/api/settings', { method: 'PUT', headers, body: JSON.stringify({ timeZone: 'America/Los_Angeles' }) })).status).toBe(200)
    const response = await (await app.request('/api/sync', { headers })).json()
    expect(response.catchUpBlocks[0]).toEqual({
      id: '2026-11-23', startAt: '2026-11-24T02:00:00.000Z', endAt: '2026-11-24T02:30:00.000Z',
      items: [{ id: 'long', title: 'example.com', site: 'example.com', url: 'https://example.com/long', estMinutes: 44 }],
    })
    expect(response.catchUpBlocks.map((block: { items: { id: string }[] }) => block.items.map((item) => item.id)))
      .toEqual([['long'], withShorts ? ['old', 'new'] : ['long'], ['long']])
    const range = await (await app.request('/mcp', { method: 'POST', headers, body: JSON.stringify({
      jsonrpc: '2.0', id: 1, method: 'tools/call',
      params: { name: 'get_range', arguments: { startDate: '2026-11-23', endDate: '2026-11-25' } },
    }) })).json()
    expect(range.result.structuredContent.days.map((day: { catchUpBlocks: unknown[] }) => day.catchUpBlocks))
      .toEqual(response.catchUpBlocks.map((block: unknown) => [block]))
    expect(response.laterItems.find((item: { id: string }) => item.id === 'long').readAt).toBeNull()
    await setLaterState(db, 'long', { action: 'read' })
    const after = await reschedule()
    expect(after.catchUpBlocks?.flatMap((block) => block.items).map((item) => item.id) ?? [])
      .toEqual(withShorts ? ['old', 'new', 'old', 'new', 'old', 'new'] : [])
  } finally {
    await close()
  }
})
