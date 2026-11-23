import { serve } from '@hono/node-server'
import { ClaudeBriefWriter } from './ai/brief.js'
import { ClaudeTaskParser } from './ai/parse-task.js'
import { ClaudeCategorySuggester } from './ai/suggest-category.js'
import { createApp } from './app.js'
import { briefJob } from './briefs.js'
import { ChangeBus } from './changes.js'
import { loadConfig } from './config.js'
import { createDb } from './db/client.js'
import { GoogleSync } from './google/sync.js'
import { refreshAllDayJudgments, repairLegacyJudgmentCursors } from './google/all-day-state.js'
import { startJobs } from './jobs.js'
import { archiveStaleLater, enrichLaterBatch } from './later-jobs.js'
import { runScheduling } from './scheduling.js'

const config = loadConfig()
const { db, close } = createDb(config.DATABASE_URL)
const sync = new GoogleSync(db, config)
const changes = new ChangeBus()
const reschedule = (reason?: string) => runScheduling(db, config, new Date(), reason)
const claude =
  config.ANTHROPIC_API_KEY === undefined ? undefined : { apiKey: config.ANTHROPIC_API_KEY, model: config.ANTHROPIC_MODEL }
const briefWriter = claude === undefined ? undefined : new ClaudeBriefWriter(claude)
const aiDeps =
  claude === undefined || briefWriter === undefined
    ? {}
    : { ai: new ClaudeTaskParser(claude), categorySuggester: new ClaudeCategorySuggester(claude), briefWriter }
let laterDirty = false
const app = createApp({ db, config, sync, reschedule, changes, laterChanged: () => { laterDirty = true }, ...aiDeps })
if (claude === undefined) console.log('[server] ANTHROPIC_API_KEY not set; /api/ai/* disabled')

const server = serve({ fetch: app.fetch, port: config.PORT }, (info) => {
  console.log(`[server] listening on port ${info.port}, public URL ${config.PUBLIC_URL}`)
})
const stopJobs = startJobs({
  sync,
  reschedule,
  changes,
  archiveLater: () => archiveStaleLater(db),
  refreshLater: async () => {
    if (await enrichLaterBatch(db)) laterDirty = true
    if (!laterDirty) return
    laterDirty = false
    try {
      await reschedule('rescheduled due to Later queue update')
      changes.publish()
    } catch (error) {
      laterDirty = true
      throw error
    }
  },
  refreshAllDayJudgments: () => refreshAllDayJudgments(db),
  repairJudgmentCursors: () => repairLegacyJudgmentCursors(db),
  ...(briefWriter === undefined ? {} : { ensureBriefs: briefJob(db, briefWriter) }),
})

let shuttingDown = false
function shutdown(signal: string): void {
  if (shuttingDown) return
  shuttingDown = true
  console.log(`[server] ${signal} received, shutting down`)
  stopJobs()
  server.close(() => {
    void close().finally(() => process.exit(0))
  })
  setTimeout(() => process.exit(1), 10_000).unref()
}

process.on('SIGTERM', () => shutdown('SIGTERM'))
process.on('SIGINT', () => shutdown('SIGINT'))
