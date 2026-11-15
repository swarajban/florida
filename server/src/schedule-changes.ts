import type { Placement, Unscheduled } from '@florida/scheduler'
import type { PlacementRow } from './db/schema.js'

export function placementChanges(previous: PlacementRow[], next: Placement[], options: { now?: Date; previousUnscheduled?: Unscheduled[]; unscheduled?: Unscheduled[] } = {}) {
  const now = options.now?.getTime() ?? -Infinity
  const before = previous.filter((p) => p.endAt.getTime() > now).map((p) => ({ taskId: p.taskId, start: p.startAt.toISOString(), end: p.endAt.toISOString(), pinned: p.pinned, lane: p.lane }))
  const after = next.filter((p) => Date.parse(p.end) > now).map((p) => ({ taskId: p.taskId, start: p.start, end: p.end, pinned: p.pinned, lane: p.lane ?? null }))
  const state = (rows: Unscheduled[] | undefined, id: string) => {
    const item = rows?.find((u) => u.taskId === id)
    return item === undefined ? null : { reason: item.reason, unplacedMinutes: item.unplacedMinutes }
  }
  const blocks = (rows: typeof before, id: string) => rows.filter((p) => p.taskId === id)
    .map(({ taskId: _, ...p }) => p).sort((a, b) => a.start.localeCompare(b.start) || a.end.localeCompare(b.end) || (a.lane ?? -1) - (b.lane ?? -1) || Number(a.pinned) - Number(b.pinned))
  return [...new Set([...before, ...after, ...(options.previousUnscheduled ?? []), ...(options.unscheduled ?? [])].map((p) => p.taskId))].flatMap((taskId) => {
    const oldBlocks = blocks(before, taskId)
    const newBlocks = blocks(after, taskId)
    const beforeUnscheduled = state(options.previousUnscheduled, taskId)
    const afterUnscheduled = state(options.unscheduled, taskId)
    if (JSON.stringify([oldBlocks, beforeUnscheduled]) === JSON.stringify([newBlocks, afterUnscheduled])) return []
    const changeType = afterUnscheduled !== null ? 'unscheduled' as const : newBlocks.length === 0 ? 'removed' as const : oldBlocks.length === 0 ? 'created' as const : 'moved' as const
    return [{ taskId, before: oldBlocks, after: newBlocks, beforeUnscheduled, afterUnscheduled, changeType, reason: 'scheduler replan' }]
  })
}
