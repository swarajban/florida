import { eq, sql } from 'drizzle-orm'
import { expect, it, vi } from 'vitest'
import { createApp } from '../src/app.js'
import { ChangeBus } from '../src/changes.js'
import { laterItems } from '../src/db/schema.js'
import { createTestDb } from './db.js'
import { FakeSync, testConfig as config } from './fixtures.js'

it('syncs Later independently of tasks and includes incremental edits and tombstones', async () => {
  const { db, close } = await createTestDb()
  try {
    const reschedule = vi.fn(() => { throw new Error('Later writes should not schedule tasks') })
    const changes = new ChangeBus()
    const publish = vi.fn()
    changes.subscribe(publish)
    const app = createApp({ db, config, sync: new FakeSync(), reschedule, changes })
    const headers = { authorization: `Bearer ${config.API_TOKEN}`, 'content-type': 'application/json' }
    const request = (method: string, path: string, body?: object) => app.request(`/api/${path}`, {
      method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
    expect((await app.request('/api/later')).status).toBe(401)
    expect((await request('PUT', 'later/invalid', { url: 'https://user:password@example.com' })).status).toBe(400)
    const earlier = '2000-01-01T00:00:00.000Z'
    const later = '2000-01-02T00:00:00.000Z'
    const old = { url: 'https://example.org', savedAt: earlier }
    expect((await request('PUT', 'later/old', old)).status).toBe(200)
    await db.update(laterItems).set({ updatedAt: new Date(earlier) }).where(eq(laterItems.id, 'old'))

    const capture = { url: 'https://WWW.Example.org/story#section', title: 'A story', source: 'share', savedAt: later }
    const created = await request('PUT', 'later/story', capture)
    expect(created.status).toBe(200)
    const row = await created.json()
    expect(row).toMatchObject({
      id: 'story', url: capture.url, canonicalUrl: 'https://www.example.org/story', title: capture.title,
      site: 'www.example.org', source: 'share', kind: 'article', estMinutes: null, savedAt: later,
      readAt: null, archivedAt: null, deletedAt: null,
    })
    expect(await (await request('PUT', 'later/story', capture)).json()).toEqual(row)
    expect((await request('PUT', 'later/story', { ...capture, url: old.url })).status).toBe(409)
    expect(await (await request('GET', 'later?limit=1&offset=1')).json()).toEqual({ items: [row] })
    const full = await (await request('GET', 'sync')).json()
    expect(full.laterItems).toHaveLength(2)
    expect(full.tasks).toEqual([])
    const since = encodeURIComponent(later)
    expect((await (await request('GET', `sync?since=${since}`)).json()).laterItems).toEqual([row])

    const state = { action: 'read', at: later }
    const read = await (await request('PUT', 'later/story', { ...capture, state })).json()
    expect(read).toMatchObject({ id: 'story', readAt: later, archivedAt: null })
    expect(await (await request('GET', 'later?status=read')).json()).toEqual({ items: [read] })
    const archived = await (await request('PATCH', 'later/story', { action: 'archive', at: later })).json()
    expect(archived).toMatchObject({ readAt: null, archivedAt: later, deletedAt: null })
    expect(await (await request('GET', 'later?status=archived')).json()).toEqual({ items: [archived] })
    const reopened = await (await request('PATCH', 'later/story', { action: 'later' })).json()
    expect(reopened).toMatchObject({ readAt: null, archivedAt: null, deletedAt: null })
    expect((await request('DELETE', 'later/story')).status).toBe(204)
    expect((await request('DELETE', 'later/story')).status).toBe(204)
    expect((await request('PUT', 'later/story', capture)).status).toBe(404)
    expect((await request('PATCH', 'later/story', state)).status).toBe(404)
    const tombstone = await (await request('GET', 'later/story')).json()
    expect(tombstone.deletedAt).toEqual(expect.any(String))
    expect((await (await request('GET', 'later?status=all')).json()).items).toHaveLength(1)
    expect((await (await request('GET', `sync?since=${since}`)).json()).laterItems).toEqual([tombstone])
    expect(publish).toHaveBeenCalled()
    expect(reschedule).not.toHaveBeenCalled()

    await db.execute(sql`drop table later_items`)
    const log = vi.spyOn(console, 'error').mockImplementation(() => {})
    try {
      const privateURL = 'https://example.org/story?signature=fixture-sensitive-value'
      const failed = await request('PUT', 'later/failure', { url: privateURL })
      expect(failed.status).toBe(500)
      expect(log.mock.calls[0]?.[1]).toMatchObject({ message: 'Could not save Later item' })
      expect(JSON.stringify(log.mock.calls)).not.toContain(privateURL)
    } finally {
      log.mockRestore()
    }
  } finally {
    await close()
  }
})
