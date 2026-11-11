import { randomBytes, randomUUID } from 'node:crypto'
import { and, eq, inArray, isNull } from 'drizzle-orm'
import type { Config } from '../config.js'
import { decrypt, encrypt } from '../crypto.js'
import type { Db } from '../db/client.js'
import { calendars, events, googleAccounts } from '../db/schema.js'
import type { CalendarRow, GoogleAccountRow } from '../db/schema.js'
import {
  GoogleApiError,
  GoogleGoneError,
  deleteEvent as deleteGoogleEvent,
  eventInstances as googleEventInstances,
  getEvent as getGoogleEvent,
  insertEvent,
  listCalendars,
  listEvents,
  mapEvent,
  patchEvent,
  refreshAccessToken,
  stopChannel,
  watchEvents,
} from './client.js'
import type { GoogleCalendarListEntry, GoogleEvent, GoogleEventWrite, ListEventsParams, OAuthConfig, Tokens } from './client.js'

const MINUTE = 60_000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR
export const FULL_SYNC_PAST_DAYS = 30
export const FULL_SYNC_FUTURE_DAYS = 365
/** Refresh the access token when it expires within this long. */
const TOKEN_SLACK = 60_000
/** Renew a webhook channel when it expires within this long. */
const WATCH_RENEWAL_LEAD = DAY

/** What the HTTP layer and jobs need from calendar sync. `GoogleSync` implements it; tests inject fakes. */
export interface CalendarSyncService {
  connectAccount(label: string, tokens: Tokens): Promise<GoogleAccountRow>
  syncAccount(account: GoogleAccountRow): Promise<void>
  syncCalendar(calendar: CalendarRow): Promise<void>
  syncAll(): Promise<void>
  ensureAllWatches(): Promise<void>
  /** Google's current copy of one event of the calendar. */
  getEvent(calendar: CalendarRow, googleId: string): Promise<GoogleEvent>
  /** Creates an event in the calendar; Google assigns the id. Returns Google's copy. */
  createEvent(calendar: CalendarRow, event: GoogleEventWrite): Promise<GoogleEvent>
  /** Expanded occurrences of a series in the given window. */
  eventInstances(calendar: CalendarRow, googleId: string, timeMin: string, timeMax: string): Promise<GoogleEvent[]>
  /** Changes only the given fields of an event. Returns Google's updated copy. */
  updateEvent(calendar: CalendarRow, googleId: string, patch: GoogleEventWrite): Promise<GoogleEvent>
  /** Deletes an event. Resolves once it is gone, including when Google had already removed it. */
  deleteEvent(calendar: CalendarRow, googleId: string): Promise<void>
}

type SyncConfig = Pick<Config, 'GOOGLE_CLIENT_ID' | 'GOOGLE_CLIENT_SECRET' | 'PUBLIC_URL' | 'TOKEN_ENCRYPTION_KEY'>

/**
 * Which calendars a newly connected account syncs before the user has picked any: its own primary
 * calendar and the group calendars it can write to. Another person's primary calendar shows up
 * with `accessRole: 'owner'` too when they shared it with "make changes and manage sharing", so
 * the role alone would pull in every coworker's calendar. Holiday, subscription, and resource
 * calendars are not the user's own time.
 */
export function selectedByDefault(entry: GoogleCalendarListEntry): boolean {
  if (entry.primary === true) return true
  const writable = entry.accessRole === 'owner' || entry.accessRole === 'writer'
  return writable && entry.id.endsWith('@group.calendar.google.com')
}

export class GoogleSync implements CalendarSyncService {
  private readonly oauth: OAuthConfig

  constructor(
    private readonly db: Db,
    private readonly config: SyncConfig,
  ) {
    this.oauth = {
      clientId: config.GOOGLE_CLIENT_ID,
      clientSecret: config.GOOGLE_CLIENT_SECRET,
      redirectUri: `${config.PUBLIC_URL}/auth/google/callback`,
    }
  }

  /** Returns a valid access token, refreshing (and persisting) it when missing or about to expire. */
  async accessTokenFor(account: GoogleAccountRow): Promise<string> {
    const expiresAt = account.accessTokenExpiresAt?.getTime() ?? 0
    if (account.accessToken !== null && expiresAt - Date.now() > TOKEN_SLACK) return account.accessToken

    const refreshToken = decrypt(account.refreshTokenEnc, this.config.TOKEN_ENCRYPTION_KEY)
    const tokens = await refreshAccessToken(this.oauth, refreshToken)
    await this.db
      .update(googleAccounts)
      .set({ accessToken: tokens.accessToken, accessTokenExpiresAt: tokens.expiresAt, updatedAt: new Date() })
      .where(eq(googleAccounts.id, account.id))
    return tokens.accessToken
  }

  /**
   * Stores a freshly authorized account (keyed by the primary calendar's id, which is the email)
   * and upserts its calendar list. Returns before any events are fetched: callers run
   * `syncAccount` afterwards, off the request path, because a first sync can take minutes.
   */
  async connectAccount(label: string, tokens: Tokens): Promise<GoogleAccountRow> {
    if (tokens.refreshToken === undefined) {
      throw new Error(
        'Google did not return a refresh token. Remove the app at https://myaccount.google.com/permissions and connect again.',
      )
    }
    const list = await listCalendars(tokens.accessToken)
    const primary = list.find((c) => c.primary === true)
    if (primary === undefined) throw new Error('Google account has no primary calendar')

    const now = new Date()
    const accountFields = {
      label,
      refreshTokenEnc: encrypt(tokens.refreshToken, this.config.TOKEN_ENCRYPTION_KEY),
      accessToken: tokens.accessToken,
      accessTokenExpiresAt: tokens.expiresAt,
      updatedAt: now,
    }
    const [account] = await this.db
      .insert(googleAccounts)
      .values({ id: randomUUID(), email: primary.id, createdAt: now, ...accountFields })
      .onConflictDoUpdate({ target: googleAccounts.email, set: accountFields })
      .returning()
    if (account === undefined) throw new Error('failed to store google account')

    for (const entry of list) {
      if (entry.deleted === true) continue
      const calendarFields = {
        summary: entry.summary ?? entry.id,
        color: entry.backgroundColor ?? null,
        accessRole: entry.accessRole,
        updatedAt: now,
      }
      await this.db
        .insert(calendars)
        .values({
          id: randomUUID(),
          accountId: account.id,
          googleId: entry.id,
          selected: selectedByDefault(entry),
          createdAt: now,
          ...calendarFields,
        })
        // `selected` is intentionally not in `set`: reconnecting keeps the user's choice.
        .onConflictDoUpdate({ target: [calendars.accountId, calendars.googleId], set: calendarFields })
    }
    return account
  }

  /** Syncs, then watches, every selected calendar of one account, the primary calendar first. */
  async syncAccount(account: GoogleAccountRow): Promise<void> {
    const selected = await this.db
      .select()
      .from(calendars)
      .where(and(eq(calendars.accountId, account.id), eq(calendars.selected, true)))
    selected.sort((a, b) => Number(b.googleId === account.email) - Number(a.googleId === account.email))
    for (const calendar of selected) {
      await this.guarded(`sync ${calendar.googleId}`, () => this.syncCalendar(calendar))
      await this.guarded(`watch ${calendar.googleId}`, () => this.ensureWatch(calendar))
    }
  }

  /**
   * Incremental sync with the stored sync token, or a full sync of [now − 30 d, now + 365 d] when
   * there is none. A 410 from Google invalidates the token: existing events are tombstoned and the
   * calendar is re-synced from scratch once.
   */
  async syncCalendar(calendar: CalendarRow): Promise<void> {
    const account = await this.accountFor(calendar)
    const token = await this.accessTokenFor(account)
    try {
      await this.sync(calendar, token, calendar.syncToken)
    } catch (err) {
      if (!(err instanceof GoogleGoneError)) throw err
      console.warn(`[google] sync token for ${calendar.googleId} expired; running a full sync`)
      const now = new Date()
      await this.db
        .update(events)
        .set({ deletedAt: now, updatedAt: now })
        .where(and(eq(events.calendarId, calendar.id), isNull(events.deletedAt)))
      await this.db.update(calendars).set({ syncToken: null, updatedAt: now }).where(eq(calendars.id, calendar.id))
      await this.sync(calendar, token, null)
    }
  }

  private async sync(calendar: CalendarRow, token: string, syncToken: string | null): Promise<void> {
    const now = new Date()
    const timeMin = new Date(now.getTime() - FULL_SYNC_PAST_DAYS * DAY).toISOString()
    const timeMax = new Date(now.getTime() + FULL_SYNC_FUTURE_DAYS * DAY).toISOString()
    const seen = new Set<string>()
    let pageToken: string | undefined
    let nextSyncToken: string | undefined

    do {
      const params: ListEventsParams = syncToken === null ? { timeMin, timeMax } : { syncToken }
      if (pageToken !== undefined) params.pageToken = pageToken
      const page = await listEvents(token, calendar.googleId, params)
      for (const item of page.items) {
        seen.add(item.id)
        const row = mapEvent(calendar.id, item, now)
        await this.db
          .insert(events)
          .values({ id: randomUUID(), ...row })
          .onConflictDoUpdate({ target: [events.calendarId, events.googleId], set: row })
      }
      pageToken = page.nextPageToken
      if (page.nextSyncToken !== undefined) nextSyncToken = page.nextSyncToken
    } while (pageToken !== undefined)

    if (syncToken === null) {
      // Full sync: anything we hold that Google no longer returned is gone.
      const live = await this.db
        .select({ id: events.id, googleId: events.googleId })
        .from(events)
        .where(and(eq(events.calendarId, calendar.id), isNull(events.deletedAt)))
      const stale = live.filter((e) => !seen.has(e.googleId)).map((e) => e.id)
      if (stale.length > 0) {
        await this.db.update(events).set({ deletedAt: now, updatedAt: now }).where(inArray(events.id, stale))
      }
    }

    await this.db
      .update(calendars)
      .set({ syncToken: nextSyncToken ?? syncToken, lastSyncedAt: now, updatedAt: now })
      .where(eq(calendars.id, calendar.id))
  }

  /** Creates a push channel when the calendar has none or the current one expires within 24 h. */
  async ensureWatch(calendar: CalendarRow): Promise<void> {
    const expiresAt = calendar.channelExpiresAt?.getTime() ?? 0
    if (calendar.channelId !== null && expiresAt - Date.now() > WATCH_RENEWAL_LEAD) return

    const account = await this.accountFor(calendar)
    const token = await this.accessTokenFor(account)
    const channelId = randomUUID()
    const channelToken = randomBytes(32).toString('hex')
    const watch = await watchEvents(token, calendar.googleId, {
      id: channelId,
      token: channelToken,
      address: `${this.config.PUBLIC_URL}/webhooks/google`,
    })

    if (calendar.channelId !== null && calendar.channelResourceId !== null) {
      try {
        await stopChannel(token, calendar.channelId, calendar.channelResourceId)
      } catch (err) {
        console.warn(`[google] could not stop old channel ${calendar.channelId}:`, messageOf(err))
      }
    }

    await this.db
      .update(calendars)
      .set({
        channelId,
        channelResourceId: watch.resourceId,
        channelToken,
        channelExpiresAt: watch.expiration,
        updatedAt: new Date(),
      })
      .where(eq(calendars.id, calendar.id))
  }

  async syncAll(): Promise<void> {
    for (const calendar of await this.selectedCalendars()) {
      await this.guarded(`sync ${calendar.googleId}`, () => this.syncCalendar(calendar))
    }
  }

  async ensureAllWatches(): Promise<void> {
    for (const calendar of await this.selectedCalendars()) {
      await this.guarded(`watch ${calendar.googleId}`, () => this.ensureWatch(calendar))
    }
  }

  // ---- Event writes: one Google call each. The rows are owned by the caller (see events.ts). ----

  async getEvent(calendar: CalendarRow, googleId: string): Promise<GoogleEvent> {
    return getGoogleEvent(await this.tokenFor(calendar), calendar.googleId, googleId)
  }

  async createEvent(calendar: CalendarRow, event: GoogleEventWrite): Promise<GoogleEvent> {
    return insertEvent(await this.tokenFor(calendar), calendar.googleId, event)
  }

  async eventInstances(calendar: CalendarRow, googleId: string, timeMin: string, timeMax: string): Promise<GoogleEvent[]> {
    return googleEventInstances(await this.tokenFor(calendar), calendar.googleId, googleId, timeMin, timeMax)
  }

  async updateEvent(calendar: CalendarRow, googleId: string, patch: GoogleEventWrite): Promise<GoogleEvent> {
    return patchEvent(await this.tokenFor(calendar), calendar.googleId, googleId, patch)
  }

  async deleteEvent(calendar: CalendarRow, googleId: string): Promise<void> {
    try {
      await deleteGoogleEvent(await this.tokenFor(calendar), calendar.googleId, googleId)
    } catch (err) {
      // 404: Google never had it (or no longer shows it); 410: already deleted. Gone either way.
      if (err instanceof GoogleApiError && (err.status === 404 || err.status === 410)) return
      throw err
    }
  }

  private async tokenFor(calendar: CalendarRow): Promise<string> {
    return this.accessTokenFor(await this.accountFor(calendar))
  }

  private selectedCalendars(): Promise<CalendarRow[]> {
    return this.db.select().from(calendars).where(eq(calendars.selected, true))
  }

  private async accountFor(calendar: CalendarRow): Promise<GoogleAccountRow> {
    const [account] = await this.db
      .select()
      .from(googleAccounts)
      .where(eq(googleAccounts.id, calendar.accountId))
      .limit(1)
    if (account === undefined) throw new Error(`google account ${calendar.accountId} not found`)
    return account
  }

  /** Runs one per-calendar step; a failure is logged and does not stop the others. */
  private async guarded(what: string, fn: () => Promise<void>): Promise<void> {
    try {
      await fn()
    } catch (err) {
      console.error(`[google] ${what} failed:`, messageOf(err))
    }
  }
}

function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}
