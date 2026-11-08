import type { DeadlineType, Priority, ScheduleWindow } from '@florida/scheduler'
import { boolean, index, integer, jsonb, pgTable, text, timestamp, uniqueIndex } from 'drizzle-orm/pg-core'

const ts = (name: string) => timestamp(name, { withTimezone: true, mode: 'date' })

export const schedules = pgTable('schedules', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  timeZone: text('time_zone').notNull(),
  windows: jsonb('windows').$type<ScheduleWindow[]>().notNull(),
  createdAt: ts('created_at').notNull().defaultNow(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
  deletedAt: ts('deleted_at'),
})

export const projects = pgTable('projects', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  color: text('color'),
  scheduleId: text('schedule_id')
    .notNull()
    .references(() => schedules.id),
  sortOrder: integer('sort_order').notNull().default(0),
  createdAt: ts('created_at').notNull().defaultNow(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
  deletedAt: ts('deleted_at'),
})

export const tasks = pgTable(
  'tasks',
  {
    id: text('id').primaryKey(),
    projectId: text('project_id')
      .notNull()
      .references(() => projects.id),
    title: text('title').notNull(),
    notes: text('notes'),
    durationMinutes: integer('duration_minutes').notNull(),
    minChunkMinutes: integer('min_chunk_minutes'),
    priority: text('priority').$type<Priority>().notNull(),
    deadlineType: text('deadline_type').$type<DeadlineType>().notNull(),
    dueAt: ts('due_at'),
    startAt: ts('start_at'),
    scheduleId: text('schedule_id').references(() => schedules.id),
    pinnedStart: ts('pinned_start'),
    completedMinutes: integer('completed_minutes').notNull().default(0),
    completedAt: ts('completed_at'),
    createdAt: ts('created_at').notNull().defaultNow(),
    updatedAt: ts('updated_at').notNull().defaultNow(),
    deletedAt: ts('deleted_at'),
  },
  (t) => [index('tasks_updated_at_idx').on(t.updatedAt)],
)

/** Scheduler output. Derived data: replaced wholesale on every run. */
export const placements = pgTable('placements', {
  id: text('id').primaryKey(),
  taskId: text('task_id')
    .notNull()
    .references(() => tasks.id, { onDelete: 'cascade' }),
  startAt: ts('start_at').notNull(),
  endAt: ts('end_at').notNull(),
  pinned: boolean('pinned').notNull(),
  computedAt: ts('computed_at').notNull(),
})

export const googleAccounts = pgTable('google_accounts', {
  id: text('id').primaryKey(),
  email: text('email').notNull().unique(),
  label: text('label').notNull(),
  refreshTokenEnc: text('refresh_token_enc').notNull(),
  accessToken: text('access_token'),
  accessTokenExpiresAt: ts('access_token_expires_at'),
  createdAt: ts('created_at').notNull().defaultNow(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
})

export const calendars = pgTable(
  'calendars',
  {
    id: text('id').primaryKey(),
    accountId: text('account_id')
      .notNull()
      .references(() => googleAccounts.id),
    googleId: text('google_id').notNull(),
    summary: text('summary').notNull(),
    color: text('color'),
    accessRole: text('access_role').notNull(),
    selected: boolean('selected').notNull().default(true),
    syncToken: text('sync_token'),
    channelId: text('channel_id'),
    channelResourceId: text('channel_resource_id'),
    channelToken: text('channel_token'),
    channelExpiresAt: ts('channel_expires_at'),
    lastSyncedAt: ts('last_synced_at'),
    createdAt: ts('created_at').notNull().defaultNow(),
    updatedAt: ts('updated_at').notNull().defaultNow(),
  },
  (t) => [uniqueIndex('calendars_account_google_idx').on(t.accountId, t.googleId)],
)

export const events = pgTable(
  'events',
  {
    id: text('id').primaryKey(),
    calendarId: text('calendar_id')
      .notNull()
      .references(() => calendars.id, { onDelete: 'cascade' }),
    googleId: text('google_id').notNull(),
    status: text('status').notNull(),
    summary: text('summary'),
    location: text('location'),
    startAt: ts('start_at'),
    endAt: ts('end_at'),
    allDay: boolean('all_day').notNull(),
    transparency: text('transparency'),
    responseStatus: text('response_status'),
    htmlLink: text('html_link'),
    updatedAt: ts('updated_at').notNull().defaultNow(),
    deletedAt: ts('deleted_at'),
  },
  (t) => [
    uniqueIndex('events_calendar_google_idx').on(t.calendarId, t.googleId),
    index('events_updated_at_idx').on(t.updatedAt),
  ],
)

export type ScheduleRow = typeof schedules.$inferSelect
export type ProjectRow = typeof projects.$inferSelect
export type TaskRow = typeof tasks.$inferSelect
export type PlacementRow = typeof placements.$inferSelect
export type GoogleAccountRow = typeof googleAccounts.$inferSelect
export type CalendarRow = typeof calendars.$inferSelect
export type EventRow = typeof events.$inferSelect
export type NewEventRow = typeof events.$inferInsert
