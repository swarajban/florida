import type { DeadlineType, Priority, TaskContext, UnscheduledReason } from '@florida/scheduler'
import { sql } from 'drizzle-orm'
import { boolean, index, integer, jsonb, pgTable, text, timestamp, uniqueIndex } from 'drizzle-orm/pg-core'
import type { RecurrenceRule, RecurringTaskTemplate } from '../recurrence.js'

const ts = (name: string) => timestamp(name, { withTimezone: true, mode: 'date' })

export type CategoryArea = 'work' | 'personal'

/** The user's one row of preferences; the routine's time zone lives here. Seeded, never deleted. */
export const settings = pgTable('settings', {
  id: text('id').primaryKey(),
  timeZone: text('time_zone').notNull(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
})

/**
 * The weekly routine: when each kind of task may be worked on, as wall-clock windows in the
 * settings time zone. Time outside every block (sleep, family, gym) is never scheduled, except
 * that a task which cannot otherwise make its hard deadline may spill into the scheduler's
 * overflow window (07:00–23:00) so the deadline is met rather than silently missed.
 *
 * An `optional` block is time the user might work but does not count on (a weekday evening).
 * The plan never uses it; the scheduler only suggests what to do there (`optionalPlacements`).
 */
export const routineBlocks = pgTable('routine_blocks', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  days: jsonb('days').$type<number[]>().notNull(),
  start: text('start_time').notNull(),
  end: text('end_time').notNull(),
  allows: jsonb('allows').$type<TaskContext[]>().notNull(),
  optional: boolean('optional').notNull().default(false),
  createdAt: ts('created_at').notNull().defaultNow(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
  deletedAt: ts('deleted_at'),
})

/** A legacy schedule window: weekdays (0 = Sunday) and "HH:MM" bounds in the schedule's zone. */
export interface ScheduleWindow {
  days: number[]
  start: string
  end: string
}

/** Superseded by `routineBlocks`; kept while shipped clients still require it in `/api/sync`. */
export const schedules = pgTable('schedules', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  timeZone: text('time_zone').notNull(),
  windows: jsonb('windows').$type<ScheduleWindow[]>().notNull(),
  createdAt: ts('created_at').notNull().defaultNow(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
  deletedAt: ts('deleted_at'),
})

export const categories = pgTable('categories', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  color: text('color'),
  /** Null for the inbox, whose tasks are unfiled. */
  area: text('area').$type<CategoryArea>(),
  scheduleId: text('schedule_id')
    .notNull()
    .references(() => schedules.id),
  sortOrder: integer('sort_order').notNull().default(0),
  createdAt: ts('created_at').notNull().defaultNow(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
  deletedAt: ts('deleted_at'),
})

/** Templates survive completed occurrences. Only actual occurrences are synced as tasks. */
export const taskRecurrences = pgTable('task_recurrences', {
  id: text('id').primaryKey(),
  revision: text('revision').notNull().default(sql`gen_random_uuid()::text`),
  rule: jsonb('rule').$type<RecurrenceRule>().notNull(),
  template: jsonb('template').$type<RecurringTaskTemplate>().notNull(),
  fromDate: text('from_date').notNull(),
  createdAt: ts('created_at').notNull().defaultNow(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
  deletedAt: ts('deleted_at'),
})

export const tasks = pgTable(
  'tasks',
  {
    id: text('id').primaryKey(),
    categoryId: text('category_id')
      .notNull()
      .references(() => categories.id),
    title: text('title').notNull(),
    notes: text('notes'),
    durationMinutes: integer('duration_minutes').notNull(),
    minChunkMinutes: integer('min_chunk_minutes'),
    priority: text('priority').$type<Priority>().notNull(),
    deadlineType: text('deadline_type').$type<DeadlineType>().notNull(),
    dueAt: ts('due_at'),
    startAt: ts('start_at'),
    scheduleId: text('schedule_id').references(() => schedules.id),
    context: text('context').$type<TaskContext>().notNull().default('computer'),
    pinnedStart: ts('pinned_start'),
    recurrence: jsonb('recurrence').$type<RecurrenceRule>(),
    recurrenceSeriesId: text('recurrence_series_id').references(() => taskRecurrences.id),
    recurrenceDate: text('recurrence_date'),
    // Retained after detaching from a stopped series, so stale snapshots cannot enable it again.
    recurrenceRevision: text('recurrence_revision'),
    completedMinutes: integer('completed_minutes').notNull().default(0),
    completedAt: ts('completed_at'),
    createdAt: ts('created_at').notNull().defaultNow(),
    updatedAt: ts('updated_at').notNull().defaultNow(),
    deletedAt: ts('deleted_at'),
  },
  (t) => [
    index('tasks_updated_at_idx').on(t.updatedAt),
    uniqueIndex('tasks_recurrence_date_idx').on(t.recurrenceSeriesId, t.recurrenceDate),
  ],
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

/**
 * Scheduler output: what to do in an optional routine block if the user chooses to work then.
 * Suggestions, not the plan: a task listed here keeps its `placements`. Derived data, replaced
 * with `placements`. Kept apart from them so nothing that reads the plan has to filter.
 */
export const optionalPlacements = pgTable('optional_placements', {
  id: text('id').primaryKey(),
  taskId: text('task_id')
    .notNull()
    .references(() => tasks.id, { onDelete: 'cascade' }),
  /** The optional routine block; not a foreign key, since the rows are replaced on every run. */
  blockId: text('block_id').notNull(),
  startAt: ts('start_at').notNull(),
  endAt: ts('end_at').notNull(),
  computedAt: ts('computed_at').notNull(),
})

/** Scheduler output: tasks it could not (fully) place. Derived data, replaced with `placements`. */
export const unscheduled = pgTable('unscheduled', {
  taskId: text('task_id')
    .primaryKey()
    .references(() => tasks.id, { onDelete: 'cascade' }),
  reason: text('reason').$type<UnscheduledReason>().notNull(),
  unplacedMinutes: integer('unplaced_minutes').notNull(),
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

export type AttendeeResponseStatus = 'needsAction' | 'declined' | 'tentative' | 'accepted'

export interface EventAttendee {
  email: string
  displayName: string | null
  responseStatus: AttendeeResponseStatus
  organizer: boolean
  self: boolean
  optional: boolean
}

export interface EventOrganizer {
  email: string
  displayName: string | null
  self: boolean
}

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
    description: text('description'),
    conferenceUrl: text('conference_url'),
    attendees: jsonb('attendees').$type<EventAttendee[]>(),
    organizer: jsonb('organizer').$type<EventOrganizer>(),
    eventType: text('event_type'),
    recurringEventId: text('recurring_event_id'),
    icalUid: text('ical_uid'),
    updatedAt: ts('updated_at').notNull().defaultNow(),
    deletedAt: ts('deleted_at'),
  },
  (t) => [
    uniqueIndex('events_calendar_google_idx').on(t.calendarId, t.googleId),
    index('events_updated_at_idx').on(t.updatedAt),
  ],
)

export type SettingsRow = typeof settings.$inferSelect
export type RoutineBlockRow = typeof routineBlocks.$inferSelect
export type ScheduleRow = typeof schedules.$inferSelect
export type CategoryRow = typeof categories.$inferSelect
export type TaskRow = typeof tasks.$inferSelect
export type PlacementRow = typeof placements.$inferSelect
export type OptionalPlacementRow = typeof optionalPlacements.$inferSelect
export type UnscheduledRow = typeof unscheduled.$inferSelect
export type GoogleAccountRow = typeof googleAccounts.$inferSelect
export type CalendarRow = typeof calendars.$inferSelect
export type EventRow = typeof events.$inferSelect
export type NewEventRow = typeof events.$inferInsert
