import { serve } from '@hono/node-server'
import { createApp } from './app.js'
import { loadConfig } from './config.js'
import { createDb } from './db/client.js'
import { GoogleSync } from './google/sync.js'
import { startJobs } from './jobs.js'
import { runScheduling } from './scheduling.js'

const config = loadConfig()
const { db, close } = createDb(config.DATABASE_URL)
const sync = new GoogleSync(db, config)
const reschedule = () => runScheduling(db, config)
const app = createApp({ db, config, sync, reschedule })

const server = serve({ fetch: app.fetch, port: config.PORT }, (info) => {
  console.log(`[server] listening on port ${info.port}, public URL ${config.PUBLIC_URL}`)
})
const stopJobs = startJobs({ sync, reschedule })

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
