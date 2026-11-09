import type { Config } from '../src/config.js'
import type { CalendarRow, GoogleAccountRow } from '../src/db/schema.js'
import { GoogleApiError } from '../src/google/client.js'
import type { GoogleEvent, GoogleEventDateTime, GoogleEventWrite } from '../src/google/client.js'
import type { CalendarSyncService } from '../src/google/sync.js'

export const testConfig: Config = {
  DATABASE_URL: 'postgres://unused',
  API_TOKEN: 'test-token-0123456789abcdef',
  TOKEN_ENCRYPTION_KEY: '00'.repeat(32),
  GOOGLE_CLIENT_ID: 'client-id',
  GOOGLE_CLIENT_SECRET: 'client-secret',
  PUBLIC_URL: 'https://florida.test',
  PORT: 8080,
  HORIZON_DAYS: 28,
  ANTHROPIC_MODEL: 'claude-test-1',
}

export interface FakeEventWrite {
  method: 'insert' | 'patch' | 'delete'
  /** The calendar's Google id, as the request path would carry it. */
  calendarId: string
  googleId?: string
  body?: GoogleEventWrite
}

/**
 * Records sync calls instead of talking to Google. Event writes go to an in-memory copy of
 * Google's calendar (`googleEvents`) that applies Google's patch semantics and, like Google,
 * refuses an insert under an id it already holds (409).
 */
export class FakeSync implements CalendarSyncService {
  syncCalendarCalls: CalendarRow[] = []
  syncAccountCalls: GoogleAccountRow[] = []
  /** When set, `syncAccount` waits on it, so a test can observe what happens while a first sync is still running. */
  syncAccountGate: Promise<void> | undefined
  syncAllCalls = 0
  /** Google's copy of every event created through or seeded into this fake, by Google id. */
  googleEvents = new Map<string, GoogleEvent>()
  /** Every event write in order, as the Google client would send it. */
  eventWrites: FakeEventWrite[] = []
  /** When set, the next event write rejects with it, as a failing Google call would, and clears it. */
  nextWriteError: Error | undefined
  /** Ids are assigned as `g-<n>` from this counter. */
  nextGoogleId = 1
  async connectAccount(label: string): Promise<GoogleAccountRow> {
    const now = new Date()
    return {
      id: `account-${label}`,
      email: `${label}@example.com`,
      label,
      refreshTokenEnc: 'enc',
      accessToken: null,
      accessTokenExpiresAt: null,
      createdAt: now,
      updatedAt: now,
    }
  }
  async syncAccount(account: GoogleAccountRow): Promise<void> {
    this.syncAccountCalls.push(account)
    await this.syncAccountGate
  }
  async syncCalendar(calendar: CalendarRow): Promise<void> {
    this.syncCalendarCalls.push(calendar)
  }
  async syncAll(): Promise<void> {
    this.syncAllCalls += 1
  }
  async ensureAllWatches(): Promise<void> {}

  async getEvent(_calendar: CalendarRow, googleId: string): Promise<GoogleEvent> {
    return structuredClone(this.googleEvent(googleId))
  }
  async createEvent(calendar: CalendarRow, event: GoogleEventWrite): Promise<GoogleEvent> {
    this.failIfArmed()
    const id = event.id ?? `g-${this.nextGoogleId++}`
    if (this.googleEvents.has(id)) {
      throw new GoogleApiError(409, JSON.stringify({ error: { message: 'The requested identifier already exists.' } }))
    }
    const created = applyWrite(
      { id, status: 'confirmed', htmlLink: `https://www.google.com/calendar/event?eid=${id}`, updated: new Date().toISOString() },
      event,
    )
    this.googleEvents.set(id, created)
    this.eventWrites.push({ method: 'insert', calendarId: calendar.googleId, body: event })
    return structuredClone(created)
  }
  async updateEvent(calendar: CalendarRow, googleId: string, patch: GoogleEventWrite): Promise<GoogleEvent> {
    this.failIfArmed()
    const updated = applyWrite(this.googleEvent(googleId), patch)
    this.googleEvents.set(googleId, updated)
    this.eventWrites.push({ method: 'patch', calendarId: calendar.googleId, googleId, body: patch })
    return structuredClone(updated)
  }
  async deleteEvent(calendar: CalendarRow, googleId: string): Promise<void> {
    this.failIfArmed()
    this.googleEvents.delete(googleId)
    this.eventWrites.push({ method: 'delete', calendarId: calendar.googleId, googleId })
  }

  private googleEvent(googleId: string): GoogleEvent {
    const event = this.googleEvents.get(googleId)
    if (event === undefined) throw new GoogleApiError(404, JSON.stringify({ error: { message: 'Not Found' } }))
    return event
  }
  private failIfArmed(): void {
    const err = this.nextWriteError
    if (err === undefined) return
    this.nextWriteError = undefined
    throw err
  }
}

/** Google's patch semantics: given fields replace, `null` clears, `start`/`end` merge key by key, arrays are replaced. */
function applyWrite(current: GoogleEvent, write: GoogleEventWrite): GoogleEvent {
  const next: GoogleEvent = { ...current }
  if (write.summary !== undefined) next.summary = write.summary
  for (const key of ['location', 'description'] as const) {
    const value = write[key]
    if (value === undefined) continue
    if (value === null) delete next[key]
    else next[key] = value
  }
  for (const key of ['start', 'end'] as const) {
    const value = write[key]
    if (value === undefined) continue
    const merged: GoogleEventDateTime = { ...(next[key] ?? {}) }
    for (const part of ['date', 'dateTime'] as const) {
      const v = value[part]
      if (v === undefined) continue
      if (v === null) delete merged[part]
      else merged[part] = v
    }
    next[key] = merged
  }
  if (write.attendees !== undefined) next.attendees = write.attendees
  return next
}
