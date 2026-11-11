import type { AttendeeResponseStatus, EventAttendee, EventOrganizer, NewEventRow } from '../db/schema.js'

export const SCOPES = ['https://www.googleapis.com/auth/calendar']

const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth'
const TOKEN_URL = 'https://oauth2.googleapis.com/token'
const CALENDAR_API = 'https://www.googleapis.com/calendar/v3'

export interface OAuthConfig {
  clientId: string
  clientSecret: string
  redirectUri: string
}

export interface Tokens {
  accessToken: string
  refreshToken?: string
  expiresAt: Date
}

export class GoogleApiError extends Error {
  constructor(
    readonly status: number,
    readonly body: string,
    message = describeGoogleError(status, body),
  ) {
    super(message)
    this.name = 'GoogleApiError'
  }
}

/**
 * HTTP 410 Gone. From `events.list` it means the sync token is no longer valid and a full sync is
 * required; from a single-event method it means the event has been deleted.
 */
export class GoogleGoneError extends GoogleApiError {
  constructor(body: string) {
    super(410, body)
    this.name = 'GoogleGoneError'
  }
}

/**
 * The OAuth token endpoint refused (typically `invalid_grant`: the refresh token was revoked or
 * expired). Nothing about the request that needed the token was wrong; the account has to be
 * connected again, so callers keep retrying rather than give the request up.
 */
export class GoogleTokenError extends GoogleApiError {
  constructor(status: number, body: string) {
    super(status, body)
    this.name = 'GoogleTokenError'
  }
}

/** Google's own message (`{ error: { message } }`) when the body carries one, so clients see why. */
function describeGoogleError(status: number, body: string): string {
  const prefix = `Google API responded ${status}`
  try {
    const parsed = JSON.parse(body) as { error?: { message?: unknown } }
    const message = parsed.error?.message
    return typeof message === 'string' && message !== '' ? `${prefix}: ${message}` : prefix
  } catch {
    return prefix
  }
}

export interface GoogleCalendarListEntry {
  id: string
  summary?: string
  primary?: boolean
  accessRole: string
  backgroundColor?: string
  deleted?: boolean
}

export interface GoogleEventDateTime {
  date?: string
  dateTime?: string
  timeZone?: string
}

export interface GoogleEventAttendee {
  email?: string
  displayName?: string
  responseStatus?: string
  organizer?: boolean
  self?: boolean
  optional?: boolean
}

export interface GoogleEvent {
  id: string
  status?: string
  summary?: string
  description?: string
  location?: string
  start?: GoogleEventDateTime
  end?: GoogleEventDateTime
  transparency?: string
  htmlLink?: string
  hangoutLink?: string
  conferenceData?: { entryPoints?: { entryPointType?: string; uri?: string }[] }
  updated?: string
  attendees?: GoogleEventAttendee[]
  organizer?: { email?: string; displayName?: string; self?: boolean }
  eventType?: string
  recurringEventId?: string
  /** On an instance of a recurring event: where the series puts it, even after it was moved on its own. */
  originalStartTime?: GoogleEventDateTime
  recurrence?: string[]
  iCalUID?: string
}

/**
 * `start`/`end` as sent to Google: `date` for an all-day event, `dateTime` otherwise. Patch
 * semantics merge nested objects, so a patch that switches representation sets the other key to
 * `null`; an event holding both is rejected.
 */
export interface GoogleEventTimeWrite {
  date?: string | null
  dateTime?: string | null
  /** The IANA zone a recurring event repeats in. Only a write to a series sends it. */
  timeZone?: string
}

/** The fields of an event the apps write. On a patch, absent fields keep their value. */
export interface GoogleEventWrite {
  /**
   * Insert only: the id to create the event under (5–1024 base32hex characters), so a retry of a
   * create whose reply was lost gets 409 instead of a second event. Absent, Google assigns one.
   */
  id?: string
  summary?: string
  location?: string | null
  description?: string | null
  start?: GoogleEventTimeWrite
  end?: GoogleEventTimeWrite
  recurrence?: string[]
  /** Replaced wholesale by Google, so an RSVP re-sends every attendee. */
  attendees?: GoogleEventAttendee[]
}

export type ListEventsParams =
  | { syncToken: string; pageToken?: string }
  | { timeMin: string; timeMax: string; pageToken?: string }

export interface ListEventsResult {
  items: GoogleEvent[]
  nextPageToken?: string
  nextSyncToken?: string
}

export function authorizationUrl(
  cfg: Pick<OAuthConfig, 'clientId' | 'redirectUri'>,
  state: string,
  loginHint?: string,
): string {
  const params = new URLSearchParams({
    client_id: cfg.clientId,
    redirect_uri: cfg.redirectUri,
    response_type: 'code',
    scope: SCOPES.join(' '),
    access_type: 'offline',
    prompt: 'consent',
    include_granted_scopes: 'true',
    state,
  })
  if (loginHint !== undefined) params.set('login_hint', loginHint)
  return `${AUTH_URL}?${params.toString()}`
}

interface TokenResponse {
  access_token: string
  expires_in: number
  refresh_token?: string
}

async function tokenRequest(body: Record<string, string>): Promise<Tokens> {
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString(),
  })
  if (!res.ok) throw new GoogleTokenError(res.status, await res.text())
  const json = (await res.json()) as TokenResponse
  const tokens: Tokens = {
    accessToken: json.access_token,
    expiresAt: new Date(Date.now() + json.expires_in * 1000),
  }
  if (json.refresh_token !== undefined) tokens.refreshToken = json.refresh_token
  return tokens
}

export function exchangeCode(cfg: OAuthConfig, code: string): Promise<Tokens> {
  return tokenRequest({
    code,
    client_id: cfg.clientId,
    client_secret: cfg.clientSecret,
    redirect_uri: cfg.redirectUri,
    grant_type: 'authorization_code',
  })
}

export function refreshAccessToken(cfg: Pick<OAuthConfig, 'clientId' | 'clientSecret'>, refreshToken: string): Promise<Tokens> {
  return tokenRequest({
    refresh_token: refreshToken,
    client_id: cfg.clientId,
    client_secret: cfg.clientSecret,
    grant_type: 'refresh_token',
  })
}

async function apiFetch<T>(accessToken: string, url: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(url, {
    ...init,
    headers: { ...(init.headers ?? {}), authorization: `Bearer ${accessToken}` },
  })
  if (res.status === 410) throw new GoogleGoneError(await res.text())
  if (!res.ok) throw new GoogleApiError(res.status, await res.text())
  if (res.status === 204) return undefined as T
  return (await res.json()) as T
}

export async function listCalendars(accessToken: string): Promise<GoogleCalendarListEntry[]> {
  const out: GoogleCalendarListEntry[] = []
  let pageToken: string | undefined
  do {
    const params = new URLSearchParams({ maxResults: '250', showDeleted: 'false' })
    if (pageToken !== undefined) params.set('pageToken', pageToken)
    const page = await apiFetch<{ items?: GoogleCalendarListEntry[]; nextPageToken?: string }>(
      accessToken,
      `${CALENDAR_API}/users/me/calendarList?${params.toString()}`,
    )
    out.push(...(page.items ?? []))
    pageToken = page.nextPageToken
  } while (pageToken !== undefined)
  return out
}

export async function listEvents(
  accessToken: string,
  calendarId: string,
  params: ListEventsParams,
): Promise<ListEventsResult> {
  const query = new URLSearchParams({ singleEvents: 'true', maxResults: '2500' })
  if ('syncToken' in params) {
    // Google rejects timeMin/timeMax alongside a syncToken.
    query.set('syncToken', params.syncToken)
  } else {
    query.set('timeMin', params.timeMin)
    query.set('timeMax', params.timeMax)
  }
  if (params.pageToken !== undefined) query.set('pageToken', params.pageToken)
  const page = await apiFetch<{ items?: GoogleEvent[]; nextPageToken?: string; nextSyncToken?: string }>(
    accessToken,
    `${CALENDAR_API}/calendars/${encodeURIComponent(calendarId)}/events?${query.toString()}`,
  )
  const result: ListEventsResult = { items: page.items ?? [] }
  if (page.nextPageToken !== undefined) result.nextPageToken = page.nextPageToken
  if (page.nextSyncToken !== undefined) result.nextSyncToken = page.nextSyncToken
  return result
}

export interface WatchRequest {
  id: string
  token: string
  address: string
}

export async function watchEvents(
  accessToken: string,
  calendarId: string,
  watch: WatchRequest,
): Promise<{ resourceId: string; expiration: Date }> {
  const res = await apiFetch<{ resourceId: string; expiration?: string }>(
    accessToken,
    `${CALENDAR_API}/calendars/${encodeURIComponent(calendarId)}/events/watch`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ id: watch.id, type: 'web_hook', address: watch.address, token: watch.token }),
    },
  )
  // Google returns expiration as a millisecond epoch string.
  const expiration = res.expiration !== undefined ? new Date(Number(res.expiration)) : new Date(Date.now() + 7 * 24 * 3600 * 1000)
  return { resourceId: res.resourceId, expiration }
}

export async function stopChannel(accessToken: string, id: string, resourceId: string): Promise<void> {
  await apiFetch<void>(accessToken, `${CALENDAR_API}/channels/stop`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ id, resourceId }),
  })
}

// Event writes notify guests like the Google Calendar app does: the organizer sees an RSVP, guests
// see a moved or cancelled meeting. Google warns that `none` can keep events from syncing at all.
const SEND_UPDATES = 'sendUpdates=all'

function eventsUrl(calendarId: string, eventId?: string): string {
  const base = `${CALENDAR_API}/calendars/${encodeURIComponent(calendarId)}/events`
  return eventId === undefined ? base : `${base}/${encodeURIComponent(eventId)}`
}

/** Google's current copy of one event. */
export function getEvent(accessToken: string, calendarId: string, eventId: string): Promise<GoogleEvent> {
  return apiFetch<GoogleEvent>(accessToken, eventsUrl(calendarId, eventId))
}

/** Creates an event; Google assigns the id and returns the full event. */
export function insertEvent(accessToken: string, calendarId: string, event: GoogleEventWrite): Promise<GoogleEvent> {
  return apiFetch<GoogleEvent>(accessToken, `${eventsUrl(calendarId)}?${SEND_UPDATES}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(event),
  })
}

/** Google's expanded instances, including every page. Never return the series master. */
export async function eventInstances(
  accessToken: string, calendarId: string, eventId: string, timeMin: string, timeMax: string,
): Promise<GoogleEvent[]> {
  const query = new URLSearchParams({ timeMin, timeMax, maxResults: '2500', showDeleted: 'false' })
  const instances: GoogleEvent[] = []
  let next: string | undefined
  do {
    if (next !== undefined) query.set('pageToken', next)
    const page = await apiFetch<{ items?: GoogleEvent[]; nextPageToken?: string }>(
      accessToken, `${eventsUrl(calendarId, eventId)}/instances?${query.toString()}`,
    )
    instances.push(...page.items ?? [])
    next = page.nextPageToken
  } while (next !== undefined)
  return instances
}

/** Patches an event (only the given fields change) and returns Google's updated copy. */
export function patchEvent(
  accessToken: string,
  calendarId: string,
  eventId: string,
  patch: GoogleEventWrite,
): Promise<GoogleEvent> {
  return apiFetch<GoogleEvent>(accessToken, `${eventsUrl(calendarId, eventId)}?${SEND_UPDATES}`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(patch),
  })
}

/** Deletes an event. Google answers 204; a 404 or 410 means it was already gone. */
export async function deleteEvent(accessToken: string, calendarId: string, eventId: string): Promise<void> {
  await apiFetch<void>(accessToken, `${eventsUrl(calendarId, eventId)}?${SEND_UPDATES}`, { method: 'DELETE' })
}

/**
 * Maps a Google event to our events row. Cancelled events become tombstones. `updatedAt` is the
 * server's write time rather than Google's `updated`, so `/api/sync?since=` cursors see every change.
 */
export function mapEvent(calendarId: string, e: GoogleEvent, now: Date = new Date()): Omit<NewEventRow, 'id'> {
  const allDay = e.start?.date !== undefined
  const status = e.status ?? 'confirmed'
  const cancelled = status === 'cancelled'
  return {
    calendarId,
    googleId: e.id,
    status,
    summary: e.summary ?? null,
    location: e.location ?? null,
    startAt: toDate(e.start),
    endAt: toDate(e.end),
    allDay,
    transparency: e.transparency ?? null,
    responseStatus: e.attendees?.find((a) => a.self === true)?.responseStatus ?? null,
    htmlLink: e.htmlLink ?? null,
    description: e.description ?? null,
    conferenceUrl: conferenceUrl(e),
    attendees: e.attendees === undefined ? null : e.attendees.flatMap(mapAttendee),
    organizer: e.organizer?.email === undefined ? null : mapOrganizer(e.organizer.email, e.organizer),
    eventType: e.eventType ?? null,
    recurringEventId: e.recurringEventId ?? null,
    icalUid: e.iCalUID ?? null,
    updatedAt: now,
    deletedAt: cancelled ? now : null,
  }
}

/** Meet link when Google set one, else the video entry point of any other conference solution. */
function conferenceUrl(e: GoogleEvent): string | null {
  if (e.hangoutLink !== undefined) return e.hangoutLink
  return e.conferenceData?.entryPoints?.find((p) => p.entryPointType === 'video' && p.uri !== undefined)?.uri ?? null
}

const RESPONSE_STATUSES: readonly string[] = ['needsAction', 'declined', 'tentative', 'accepted']

/** Attendees without an email cannot be shown or contacted, so they are dropped. */
function mapAttendee(a: GoogleEventAttendee): EventAttendee[] {
  if (a.email === undefined) return []
  const responseStatus = (
    a.responseStatus !== undefined && RESPONSE_STATUSES.includes(a.responseStatus) ? a.responseStatus : 'needsAction'
  ) as AttendeeResponseStatus
  return [
    {
      email: a.email,
      displayName: a.displayName ?? null,
      responseStatus,
      organizer: a.organizer ?? false,
      self: a.self ?? false,
      optional: a.optional ?? false,
    },
  ]
}

function mapOrganizer(email: string, o: { displayName?: string; self?: boolean }): EventOrganizer {
  return { email, displayName: o.displayName ?? null, self: o.self ?? false }
}

function toDate(dt: GoogleEventDateTime | undefined): Date | null {
  if (dt === undefined) return null
  if (dt.dateTime !== undefined) return new Date(dt.dateTime)
  if (dt.date !== undefined) return new Date(`${dt.date}T00:00:00Z`)
  return null
}
