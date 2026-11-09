import { pathToFileURL } from 'node:url'
import { createDb } from './db/client.js'
import type { Db } from './db/client.js'
import { INBOX_CATEGORY_ID, SETTINGS_ID } from './db/queries.js'
import { categories, routineBlocks, schedules, settings } from './db/schema.js'
import type { ScheduleWindow } from './db/schema.js'

const LA = 'America/Los_Angeles'
const WEEKDAYS = [1, 2, 3, 4, 5]

const SETTINGS = { id: SETTINGS_ID, timeZone: LA }

/**
 * Home days Mon/Thu/Fri end when the gym run starts at 15:30; office days are Tue (after the
 * morning gym) and Wed, until the 16:20 drive to school pickup. Early mornings, evenings, and
 * weekends are family time and have no block, so nothing is ever scheduled there.
 */
const SEED_ROUTINE: (typeof routineBlocks.$inferInsert)[] = [
  { id: 'home', name: 'Home', days: [1, 4, 5], start: '09:00', end: '15:30', allows: ['computer', 'errand', 'home'] },
  { id: 'office-tue', name: 'Office', days: [2], start: '10:15', end: '16:20', allows: ['computer', 'office'] },
  { id: 'office-wed', name: 'Office', days: [3], start: '09:00', end: '16:20', allows: ['computer', 'office'] },
]

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

const INBOX = { id: INBOX_CATEGORY_ID, name: 'Inbox', scheduleId: 'work', sortOrder: 0 }

/** Created once; later edits (or deletion) by the user are never undone by a re-seed. */
const STARTER_CATEGORIES: (typeof categories.$inferInsert)[] = [
  { id: 'work', name: 'Work', area: 'work', scheduleId: 'work', sortOrder: 1 },
  { id: 'personal', name: 'Personal', area: 'personal', scheduleId: 'personal', sortOrder: 2 },
]

/**
 * Upserts the inbox; inserts the settings, the routine, the legacy schedules and the starter
 * categories when missing, so the user's edits to those survive. Safe to run repeatedly.
 */
export async function seed(db: Db): Promise<void> {
  const now = new Date()
  await db.insert(settings).values({ ...SETTINGS, updatedAt: now }).onConflictDoNothing({ target: settings.id })
  await db
    .insert(routineBlocks)
    .values(SEED_ROUTINE.map((b) => ({ ...b, updatedAt: now })))
    .onConflictDoNothing({ target: routineBlocks.id })
  // Shipped clients still edit and delete schedules; a re-seed on every deploy must not undo that.
  await db
    .insert(schedules)
    .values(SEED_SCHEDULES.map((s) => ({ ...s, updatedAt: now })))
    .onConflictDoNothing({ target: schedules.id })
  const inbox = { name: INBOX.name, scheduleId: INBOX.scheduleId, sortOrder: INBOX.sortOrder, updatedAt: now, deletedAt: null }
  await db
    .insert(categories)
    .values({ id: INBOX.id, ...inbox })
    .onConflictDoUpdate({ target: categories.id, set: inbox })
  await db
    .insert(categories)
    .values(STARTER_CATEGORIES.map((p) => ({ ...p, updatedAt: now })))
    .onConflictDoNothing({ target: categories.id })
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
    console.log(
      `[seed] upserted ${SEED_SCHEDULES.length} schedules and the inbox; ensured settings, ${SEED_ROUTINE.length} routine blocks and ${STARTER_CATEGORIES.length} starter categories`,
    )
  } finally {
    await close()
  }
}
