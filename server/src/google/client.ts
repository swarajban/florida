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
    message = `Google API responded ${status}`,
  ) {
    super(message)
    this.name = 'GoogleApiError'
  }
}

/** HTTP 410: the sync token is no longer valid and a full sync is required. */
export class GoogleGoneError extends GoogleApiError {
  constructor(body: string) {
    super(410, body, 'Google sync token expired (410 Gone)')
    this.name = 'GoogleGoneError'
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
  iCalUID?: string
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
  if (!res.ok) throw new GoogleApiError(res.status, await res.text())
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
