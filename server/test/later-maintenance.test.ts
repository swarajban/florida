import { eq, sql } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import { laterItems } from '../src/db/schema.js'
import { archiveStaleLater, enrichLaterBatch } from '../src/later-jobs.js'
import { isPublicLaterAddress, parseLaterMetadata } from '../src/later-metadata.js'
import { saveLater, setLaterState } from '../src/later.js'
import { createTestDb } from './db.js'

const url = 'https://example.com/story'
const capture = { url, title: 'Saved title', site: 'example.com', kind: 'article' as const, estMinutes: null }
const parse = (html: string, item = capture) => parseLaterMetadata(Buffer.from(html), item)

describe('Later metadata (offline fixtures)', () => {
  it.each(['Article', 'NewsArticle', 'BlogPosting'])('uses %s JSON-LD and counts the article instead of the site chrome', (type) => {
    const html = `<meta property="og:site_name" content="Example Magazine"><title>Fallback</title>
      <script type="application/ld+json">{invalid</script>
      <script type="application/ld+json">{"@graph":[{"@type":["Thing","${type}"],"headline":"Story"}]}</script>
      <article><p>${'word '.repeat(230)}</p><p>last</p><nav>${'navigation '.repeat(461)}</nav></article>`
    expect(parse(html)).toEqual({ title: 'Story', site: 'Example Magazine', kind: 'article', estMinutes: 2 })
  })

  it('uses video duration, classifies products as other, and falls back sensibly', () => {
    expect(parse('<meta property="og:type" content="video.other"><script type="application/ld+json">{"@type":"VideoObject","name":"Demo","duration":"PT1H2M1S"}</script>'))
      .toMatchObject({ kind: 'video', estMinutes: 63, title: 'Demo' })
    expect(parse('<script type="application/ld+json">{"@type":"Product","name":"Shop"}</script>'))
      .toMatchObject({ kind: 'other', estMinutes: 5, title: 'Shop' })
    expect(parse('')).toMatchObject({ kind: 'article', estMinutes: 5, title: capture.title })
    expect(parseLaterMetadata(Buffer.from('<meta property="og:type" content="article"><article>Short.</article>'), { ...capture, estMinutes: 12 }).estMinutes)
      .toBe(12)
  })

  it('only allows public IPv4 and global unicast IPv6 for outbound connections', () => {
    for (const address of ['93.184.216.34', '2606:4700:4700::1111']) expect(isPublicLaterAddress(address)).toBe(true)
    for (const address of ['127.0.0.1', '10.0.0.1', '169.254.1.2', '::1', 'fc00::1', '2001:db8::1', '::ffff:10.0.0.1']) {
      expect(isPublicLaterAddress(address), address).toBe(false)
    }
  })
})

it('enriches once and preserves a concurrent read action', async () => {
  const { db, close } = await createTestDb()
  try {
    await saveLater(db, 'saved', { url, source: 'manual' })
    const enrich = async () => {
      await setLaterState(db, 'saved', { action: 'read' })
      return parse('<title>Fetched &amp; decoded</title><article>Story.</article>')
    }
    expect(await enrichLaterBatch(db, enrich)).toBe(true)
    expect(await enrichLaterBatch(db, enrich)).toBe(false)
    const [row] = await db.select().from(laterItems).where(eq(laterItems.id, 'saved'))
    expect(row).toMatchObject({ title: 'Fetched & decoded', estMinutes: 1, readAt: expect.any(Date), enrichedAt: expect.any(Date), archivedAt: null })
  } finally {
    await close()
  }
})

it('auto-archives only live, unread links strictly older than 30 days and updates sync time', async () => {
  const { db, close } = await createTestDb()
  try {
    const old = '2026-10-22T00:00:00.000Z'
    const now = new Date('2026-11-22T00:00:00.000Z')
    for (const id of ['old', 'boundary', 'read', 'archived', 'deleted']) {
      await saveLater(db, id, { url, source: 'manual', savedAt: id === 'boundary' ? '2026-10-23T00:00:00.000Z' : old })
    }
    await setLaterState(db, 'read', { action: 'read', at: old })
    await setLaterState(db, 'archived', { action: 'archive', at: old })
    await db.update(laterItems).set({ deletedAt: new Date(old) }).where(eq(laterItems.id, 'deleted'))
    await db.update(laterItems).set({ updatedAt: sql`'2000-01-01'::timestamptz` }).where(eq(laterItems.id, 'old'))
    expect(await archiveStaleLater(db, now)).toBe(true)
    expect(await archiveStaleLater(db, now)).toBe(false)
    const rows = Object.fromEntries((await db.select().from(laterItems)).map((row) => [row.id, row]))
    expect(rows.old).toMatchObject({ archivedAt: now, readAt: null, deletedAt: null })
    expect(rows.old?.updatedAt.getTime()).toBeGreaterThan(Date.parse(old))
    expect(rows.archived?.archivedAt).toEqual(new Date(old))
    expect([rows.boundary, rows.read, rows.deleted].map((row) => row?.archivedAt)).toEqual([null, null, null])
    expect(Object.keys(rows)).toHaveLength(5)
  } finally {
    await close()
  }
})
