import type { SchedulerResult } from '@florida/scheduler'
import type { ChangeBus } from './changes.js'
import type { BriefRow } from './db/schema.js'
import type { CalendarSyncService } from './google/sync.js'

export interface JobDeps {
  sync: Pick<CalendarSyncService, 'syncAll' | 'ensureAllWatches'>
  reschedule: () => Promise<SchedulerResult>
  /** Notified after every scheduler run so `/api/events` subscribers pull. */
  changes?: Pick<ChangeBus, 'publish'>
  /** Writes the daily brief and weekly review that are due and missing; absent when Claude is not configured. */
  ensureBriefs?: () => Promise<BriefRow[]>
}

const MINUTE = 60_000
const HOUR = 60 * MINUTE

const STARTUP_DELAY = 5_000
const WATCH_INTERVAL = 6 * HOUR
const SYNC_INTERVAL = 60 * MINUTE
/** Moves tasks whose placements slipped into the past forward even when nothing else changed. */
const RESCHEDULE_INTERVAL = 15 * MINUTE
/** How often to check whether the morning brief or the Sunday review is due. */
const BRIEF_INTERVAL = 10 * MINUTE

/** Starts the periodic jobs and returns a function that stops them. */
export function startJobs(deps: JobDeps): () => void {
  const running = new Set<string>()

  async function run(name: string, job: () => Promise<void>): Promise<void> {
    if (running.has(name)) {
      console.log(`[jobs] ${name}: skipped, previous run still active`)
      return
    }
    running.add(name)
    const started = Date.now()
    try {
      await job()
      console.log(`[jobs] ${name}: ok in ${Date.now() - started}ms`)
    } catch (err) {
      console.error(`[jobs] ${name}: failed after ${Date.now() - started}ms:`, err instanceof Error ? err.message : err)
    } finally {
      running.delete(name)
    }
  }

  const reschedule = async (): Promise<void> => {
    await deps.reschedule()
    deps.changes?.publish()
  }

  const syncAndReschedule = async (): Promise<void> => {
    await deps.sync.syncAll()
    await reschedule()
  }

  const briefs = async (): Promise<void> => {
    const written = (await deps.ensureBriefs?.()) ?? []
    if (written.length > 0) deps.changes?.publish()
  }

  const timers: NodeJS.Timeout[] = [
    setTimeout(() => {
      void run('startup', async () => {
        await deps.sync.ensureAllWatches()
        await syncAndReschedule()
        // After the first plan, so a brief written at startup describes a current one.
        await briefs()
      })
    }, STARTUP_DELAY),
    setInterval(() => void run('watches', () => deps.sync.ensureAllWatches()), WATCH_INTERVAL),
    setInterval(() => void run('sync', syncAndReschedule), SYNC_INTERVAL),
    setInterval(() => void run('reschedule', reschedule), RESCHEDULE_INTERVAL),
    setInterval(() => void run('briefs', briefs), BRIEF_INTERVAL),
  ]

  return () => {
    for (const timer of timers) clearTimeout(timer)
  }
}
