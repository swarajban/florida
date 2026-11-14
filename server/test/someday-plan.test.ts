import { eq } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import { createApp } from '../src/app.js'
import { dailyFacts, explainFacts, explainPlacement, weeklyFacts } from '../src/briefs.js'
import { optionalPlacements, placements, projects, routineBlocks, tasks, unscheduled } from '../src/db/schema.js'
import { runScheduling } from '../src/scheduling.js'
import { seed } from '../src/seed.js'
import { patchTask, upsertTask } from '../src/tasks.js'
import { createTestDb } from './db.js'
import { FakeSync, testConfig } from './fixtures.js'

const NOW = new Date('2026-11-09T17:00:00Z')
const body = { categoryId: 'work', title: 'Deferred work', durationMinutes: 60, priority: 'medium', deadlineType: 'none' } as const

describe('Someday off-plan behavior', () => {
  it('replaces stored artifacts and keeps Someday out of daily and weekly facts, including stale artifacts', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      await db.insert(projects).values({ id: 'budget', name: 'Budget', weeklyMinutes: 120 })
      await upsertTask(db, 'deferred', { ...body, projectId: 'budget' }, NOW)
      await upsertTask(db, 'done-someday', { ...body, title: 'Completed Someday', projectId: 'budget', someday: true, completedAt: NOW.toISOString(), completedMinutes: 60 }, NOW)
      await upsertTask(db, 'inbox', { ...body, categoryId: 'inbox', title: 'Inbox capture' }, NOW)
      const before = await runScheduling(db, testConfig, NOW)
      expect(before.placements.some((p) => p.taskId === 'deferred')).toBe(true)
      await patchTask(db, 'deferred', { someday: true }, NOW)
      const result = await runScheduling(db, testConfig, NOW)
      for (const artifacts of [result.placements, result.optional, result.unscheduled, result.late]) {
        expect(artifacts.some((p) => p.taskId === 'deferred')).toBe(false)
      }
      expect(result.placements.some((p) => p.taskId === 'inbox')).toBe(true)
      for (const table of [placements, optionalPlacements, unscheduled]) {
        expect(await db.select().from(table).where(eq(table.taskId, 'deferred'))).toEqual([])
      }
      const [block] = await db.select().from(routineBlocks)
      await db.insert(placements).values({ id: 'stale', taskId: 'deferred', startAt: NOW, endAt: new Date(NOW.getTime() + 3_600_000), pinned: false, computedAt: NOW })
      await db.insert(optionalPlacements).values({ id: 'stale-optional', taskId: 'deferred', blockId: block!.id, startAt: NOW, endAt: new Date(NOW.getTime() + 3_600_000), computedAt: NOW })
      await db.insert(unscheduled).values({ taskId: 'deferred', reason: 'no_fit_in_horizon', unplacedMinutes: 60, computedAt: NOW })
      for (const facts of [await dailyFacts(db, NOW), await weeklyFacts(db, NOW)]) {
        expect(JSON.stringify(facts)).not.toContain(body.title)
        expect(facts).toMatchObject({ lateCount: 0, unscheduledCount: 0, late: [], unscheduled: [] })
      }
      expect(await weeklyFacts(db, NOW)).toMatchObject({ projects: [{ name: 'Budget', openTasks: 0, minutesSpent: 0, tasksCompleted: 0 }], completed: { count: 1, titles: ['Completed Someday'] } })
      expect(await explainFacts(db, 'deferred', NOW)).toMatchObject({ task: { someday: true, planningStatus: 'Someday' }, planned: [], unscheduled: null })
      let called = false
      const explainer = { explain: async () => { called = true; return 'Unscheduled' } }
      expect(await explainPlacement(db, explainer, 'deferred', NOW)).toContain('Someday')
      expect(called).toBe(false)
      const app = createApp({ db, config: testConfig, sync: new FakeSync(), briefWriter: { ...explainer, write: async () => ({ headline: 'Brief', body: 'Brief' }) } })
      const response = await app.request('/api/ai/explain', { method: 'POST', headers: { authorization: `Bearer ${testConfig.API_TOKEN}`, 'content-type': 'application/json' }, body: JSON.stringify({ taskId: 'deferred' }) })
      expect(response.status).toBe(200)
      expect(await response.json()).toMatchObject({ explanation: expect.stringContaining('Someday') })
      const mcp = async (name: string, args: Record<string, unknown>) => {
        const response = await app.request('/mcp', {
          method: 'POST',
          headers: { authorization: `Bearer ${testConfig.API_TOKEN}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
          body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }),
        })
        expect(response.status).toBe(200)
        const json = await response.json() as { result: { isError?: boolean; structuredContent: {
          task: { id: string; someday: boolean; placements: unknown[] }
          tasks: { id: string; someday: boolean; placements: unknown[] }[]
          taskBlocks: { taskId: string }[]
        } } }
        expect(json.result.isError).not.toBe(true)
        return json.result.structuredContent
      }
      expect((await mcp('get_task', { id: 'deferred' })).task).toMatchObject({ someday: true, placements: [] })
      const listed = (await mcp('list_tasks', {})).tasks
      expect(listed.find((t) => t.id === 'deferred')).toMatchObject({ someday: true, placements: [] })
      expect(listed.find((t) => t.id === 'inbox')?.placements.length).toBeGreaterThan(0)
      const agenda = await mcp('get_agenda', { date: '2026-11-09' })
      expect(agenda.taskBlocks.some((p) => p.taskId === 'deferred')).toBe(false)
      expect(agenda.taskBlocks.some((p) => p.taskId === 'inbox')).toBe(true)
      for (const since of ['', `?since=${new Date(NOW.getTime() + 1).toISOString()}`]) {
        const response = await app.request(`/api/sync${since}`, { headers: { authorization: `Bearer ${testConfig.API_TOKEN}` } })
        expect(response.status).toBe(200)
        const synced = await response.json() as { placements: { taskId: string }[]; optionalPlacements: { taskId: string }[]; unscheduled: { taskId: string }[] }
        for (const artifacts of [synced.placements, synced.optionalPlacements, synced.unscheduled]) {
          expect(artifacts.some((p) => p.taskId === 'deferred')).toBe(false)
        }
        expect(synced.placements.some((p) => p.taskId === 'inbox')).toBe(true)
      }
      await patchTask(db, 'deferred', { someday: false }, NOW)
      const restored = await runScheduling(db, testConfig, NOW)
      expect(restored.placements.some((p) => p.taskId === 'deferred')).toBe(true)
      expect((await dailyFacts(db, NOW)).plan.some((p) => p.title === body.title)).toBe(true)
    } finally {
      await close()
    }
  })

  it('never suggests Someday work in an optional-only routine or reports it as a planning problem', async () => {
    const { db, close } = await createTestDb()
    try {
      await seed(db)
      await db.update(routineBlocks).set({ deletedAt: NOW })
      await db.insert(routineBlocks).values({ id: 'evening-only', name: 'Evening', days: [1, 2, 3, 4, 5], start: '19:00', end: '22:00', allows: ['computer'], optional: true })
      await upsertTask(db, 'deferred', { ...body, someday: true }, NOW)
      const result = await runScheduling(db, testConfig, NOW)
      expect(result).toMatchObject({ placements: [], optional: [], unscheduled: [], late: [] })
      expect(await dailyFacts(db, NOW)).toMatchObject({ plan: [], evening: [], lateCount: 0, unscheduledCount: 0 })
      await patchTask(db, 'deferred', { someday: false }, NOW)
      const restored = await runScheduling(db, testConfig, NOW)
      expect(restored.optional.some((p) => p.taskId === 'deferred')).toBe(true)
      expect(restored.unscheduled.some((p) => p.taskId === 'deferred')).toBe(true)
      expect((await db.select().from(tasks).where(eq(tasks.id, 'deferred')))[0]?.someday).toBe(false)
    } finally {
      await close()
    }
  })
})
