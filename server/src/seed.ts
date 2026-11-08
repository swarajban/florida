import { pathToFileURL } from 'node:url'
import type { ScheduleWindow } from '@florida/scheduler'
import { createDb } from './db/client.js'
import type { Db } from './db/client.js'
import { categories, schedules } from './db/schema.js'

const LA = 'America/Los_Angeles'
const WEEKDAYS = [1, 2, 3, 4, 5]

const SEED_SCHEDULES: { id: string; name: string; timeZone: string; windows: ScheduleWindow[] }[] = [
  {
    id: 'work',
    name: 'Work hours',
    timeZone: LA,
    windows: [
      { days: WEEKDAYS, start: '09:00', end: '12:00' },
      { days: WEEKDAYS, start: '13:00', end: '17:00' },
    ],
  },
  {
    id: 'personal',
    name: 'Personal',
    timeZone: LA,
    windows: [
      { days: WEEKDAYS, start: '18:00', end: '21:00' },
      { days: [0, 6], start: '10:00', end: '18:00' },
    ],
  },
]

const SEED_CATEGORIES = [{ id: 'inbox', name: 'Inbox', scheduleId: 'work', sortOrder: 0 }]

/** Upserts the default schedules and category. Safe to run repeatedly. */
export async function seed(db: Db): Promise<void> {
  const now = new Date()
  for (const s of SEED_SCHEDULES) {
    const fields = { name: s.name, timeZone: s.timeZone, windows: s.windows, updatedAt: now, deletedAt: null }
    await db
      .insert(schedules)
      .values({ id: s.id, ...fields })
      .onConflictDoUpdate({ target: schedules.id, set: fields })
  }
  for (const p of SEED_CATEGORIES) {
    const fields = { name: p.name, scheduleId: p.scheduleId, sortOrder: p.sortOrder, updatedAt: now, deletedAt: null }
    await db
      .insert(categories)
      .values({ id: p.id, ...fields })
      .onConflictDoUpdate({ target: categories.id, set: fields })
  }
}

const isMain = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href
if (isMain) {
  const url = process.env.DATABASE_URL
  if (url === undefined || url === '') {
    console.error('DATABASE_URL is required')
    process.exit(1)
  }
  const { db, close } = createDb(url)
  try {
    await seed(db)
    console.log(`[seed] upserted ${SEED_SCHEDULES.length} schedules and ${SEED_CATEGORIES.length} category`)
  } finally {
    await close()
  }
}
