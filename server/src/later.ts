import { and, DrizzleQueryError, eq, isNotNull, isNull } from 'drizzle-orm'
import type { Hono } from 'hono'
import { HTTPException } from 'hono/http-exception'
import { z } from 'zod'
import type { Db } from './db/client.js'
import { laterItems } from './db/schema.js'
import type { LaterItemRow } from './db/schema.js'
import { writeTimestamp } from './db/sync-clock.js'
import { isSafeSourceUrl } from './task-source.js'
import { isoInstant, notFound } from './validation.js'

export const laterId = z.string().min(1).max(200)
export const laterCapture = z.object({
  url: z.string().trim().max(4096).refine((url) => /^https?:\/\//i.test(url) && isSafeSourceUrl(url), 'expected a safe HTTP(S) URL'),
  title: z.string().trim().max(200).optional(),
  kind: z.enum(['article', 'video', 'other']).optional(),
  estMinutes: z.number().int().min(1).max(1440).optional(),
})
const laterAction = z.object({ action: z.enum(['read', 'later', 'archive']), at: isoInstant.optional() })
const laterPut = laterCapture.extend({
  source: z.enum(['share', 'mcp', 'manual']).default('manual'),
  savedAt: isoInstant.optional(),
  state: laterAction.optional(),
})
export const laterStatus = z.enum(['queue', 'read', 'archived', 'all']).default('queue')
export const laterPage = z.object({
  status: laterStatus,
  limit: z.number().int().min(1).max(200).default(50),
  offset: z.number().int().min(0).max(2147483647).default(0),
})

export const unreadLater = and(isNull(laterItems.archivedAt), isNull(laterItems.readAt), isNull(laterItems.deletedAt))!
export const defaultLaterMinutes = (kind: LaterItemRow['kind']): number => kind === 'video' ? 10 : 5

export function listLater(db: Db, { status, limit, offset }: z.infer<typeof laterPage>) {
  const state = status === 'archived' ? isNotNull(laterItems.archivedAt)
    : status === 'all' ? undefined
    : and(isNull(laterItems.archivedAt), status === 'read' ? isNotNull(laterItems.readAt) : isNull(laterItems.readAt))
  return db.select().from(laterItems).where(and(isNull(laterItems.deletedAt), state))
    .orderBy(laterItems.savedAt, laterItems.id).limit(limit).offset(offset)
}

function stateValues({ action, at }: z.infer<typeof laterAction>) {
  const when = at === undefined ? writeTimestamp : new Date(at)
  return { readAt: action === 'read' ? when : null, archivedAt: action === 'archive' ? when : null }
}

export async function saveLater(db: Db, id: string, body: z.infer<typeof laterPut>): Promise<LaterItemRow> {
  const url = new URL(body.url)
  url.hash = ''
  const kind = body.kind ?? (/(^|\.)(youtube\.com|youtu\.be|vimeo\.com)\.?$/.test(url.hostname) ? 'video' : 'article')
  const state = body.state === undefined ? undefined : stateValues(body.state)
  const insert = db.insert(laterItems).values({
    id, url: body.url, canonicalUrl: url.href, title: body.title || url.hostname, site: url.hostname, kind,
    estMinutes: body.estMinutes ?? null, source: body.source,
    savedAt: body.savedAt === undefined ? writeTimestamp : new Date(body.savedAt),
    updatedAt: writeTimestamp,
    ...state,
  })
  const [written] = await (state === undefined
    ? insert.onConflictDoNothing({ target: laterItems.id })
    : insert.onConflictDoUpdate({
      target: laterItems.id,
      set: { ...state, updatedAt: writeTimestamp },
      setWhere: and(isNull(laterItems.deletedAt), eq(laterItems.url, body.url))!,
    })).returning().catch((error: unknown) => {
      if (error instanceof DrizzleQueryError) throw new Error('Could not save Later item')
      throw error
    })
  if (written !== undefined) return written
  const item = await getLater(db, id)
  if (item.deletedAt !== null) throw notFound('Later item')
  if (item.url !== body.url) throw new HTTPException(409, { message: 'Later item id belongs to another URL' })
  return item
}

export async function getLater(db: Db, id: string): Promise<LaterItemRow> {
  const [item] = await db.select().from(laterItems).where(eq(laterItems.id, id))
  if (item === undefined) throw notFound('Later item')
  return item
}

export async function setLaterState(db: Db, id: string, action: z.infer<typeof laterAction>): Promise<LaterItemRow> {
  const [item] = await db.update(laterItems).set({ ...stateValues(action), updatedAt: writeTimestamp })
    .where(and(eq(laterItems.id, id), isNull(laterItems.deletedAt))).returning()
  if (item === undefined) throw notFound('Later item')
  return item
}

export function mountLater(app: Hono, db: Db, publish: () => void): void {
  const path = '/api/later'
  app.get(path, async (c) => c.json({ items: await listLater(db, laterPage.extend({
    limit: z.coerce.number().int().min(1).max(200).default(50),
    offset: z.coerce.number().int().min(0).max(2147483647).default(0),
  }).parse(c.req.query())) }))
  app.get(`${path}/:id`, async (c) => c.json(await getLater(db, c.req.param('id'))))
  app.put(`${path}/:id`, async (c) => {
    const item = await saveLater(db, laterId.parse(c.req.param('id')), laterPut.parse(await c.req.json()))
    publish()
    return c.json(item)
  })
  app.patch(`${path}/:id`, async (c) => {
    const item = await setLaterState(db, c.req.param('id'), laterAction.parse(await c.req.json()))
    publish()
    return c.json(item)
  })
  app.delete(`${path}/:id`, async (c) => {
    const id = c.req.param('id')
    const [item] = await db.update(laterItems).set({ deletedAt: writeTimestamp, updatedAt: writeTimestamp })
      .where(and(eq(laterItems.id, id), isNull(laterItems.deletedAt))).returning({ id: laterItems.id })
    if (item === undefined) await getLater(db, id)
    else publish()
    return c.body(null, 204)
  })
}
