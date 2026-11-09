import { describe, expect, it } from 'vitest'
import { mapEvent } from '../src/google/client.js'
import type { GoogleEvent } from '../src/google/client.js'

const NOW = new Date('2026-11-08T12:00:00Z')
const CAL = 'cal-1'

const timed: GoogleEvent = {
  id: 'ev-timed',
  status: 'confirmed',
  summary: 'Standup',
  location: 'Zoom',
  start: { dateTime: '2026-11-09T09:00:00-08:00', timeZone: 'America/Los_Angeles' },
  end: { dateTime: '2026-11-09T09:30:00-08:00', timeZone: 'America/Los_Angeles' },
  htmlLink: 'https://www.google.com/calendar/event?eid=abc',
  updated: '2025-01-01T00:00:00.000Z',
  attendees: [
    { email: 'boss@example.com', responseStatus: 'declined' },
    { email: 'me@example.com', self: true, responseStatus: 'accepted' },
  ],
}

const allDay: GoogleEvent = {
  id: 'ev-allday',
  status: 'confirmed',
  summary: 'Conference',
  start: { date: '2026-11-10' },
  end: { date: '2026-11-12' },
}

const cancelled: GoogleEvent = { id: 'ev-cancelled', status: 'cancelled' }

const declined: GoogleEvent = {
  id: 'ev-declined',
  status: 'confirmed',
  summary: 'Optional sync',
  start: { dateTime: '2026-11-09T15:00:00Z' },
  end: { dateTime: '2026-11-09T16:00:00Z' },
  transparency: 'transparent',
  attendees: [{ self: true, responseStatus: 'declined' }],
}

describe('mapEvent', () => {
  it('maps a timed event', () => {
    expect(mapEvent(CAL, timed, NOW)).toEqual({
      calendarId: CAL,
      googleId: 'ev-timed',
      status: 'confirmed',
      summary: 'Standup',
      location: 'Zoom',
      startAt: new Date('2026-11-09T17:00:00Z'),
      endAt: new Date('2026-11-09T17:30:00Z'),
      allDay: false,
      transparency: null,
      responseStatus: 'accepted',
      htmlLink: 'https://www.google.com/calendar/event?eid=abc',
      description: null,
      conferenceUrl: null,
      attendees: [
        { email: 'boss@example.com', displayName: null, responseStatus: 'declined', organizer: false, self: false, optional: false },
        { email: 'me@example.com', displayName: null, responseStatus: 'accepted', organizer: false, self: true, optional: false },
      ],
      organizer: null,
      eventType: null,
      recurringEventId: null,
      icalUid: null,
      updatedAt: NOW,
      deletedAt: null,
    })
  })

  it('keeps the details a detail view and a Join button need', () => {
    const row = mapEvent(
      CAL,
      {
        id: 'ev-meeting_20261109T170000Z',
        status: 'confirmed',
        summary: 'Design review',
        description: 'Agenda:\n1. Mocks\nhttps://zoom.us/j/999 (not the join link)',
        start: { dateTime: '2026-11-09T17:00:00Z' },
        end: { dateTime: '2026-11-09T18:00:00Z' },
        hangoutLink: 'https://meet.google.com/abc-defg-hij',
        conferenceData: {
          entryPoints: [
            { entryPointType: 'phone', uri: 'tel:+1-555-0100' },
            { entryPointType: 'video', uri: 'https://meet.google.com/abc-defg-hij?pli=1' },
          ],
        },
        organizer: { email: 'lead@example.com', displayName: 'Team Lead' },
        attendees: [
          { email: 'lead@example.com', displayName: 'Team Lead', organizer: true, responseStatus: 'accepted' },
          { email: 'me@example.com', self: true, responseStatus: 'tentative' },
          { email: 'pm@example.com', displayName: 'PM', optional: true, responseStatus: 'needsAction' },
        ],
        eventType: 'default',
        recurringEventId: 'ev-meeting',
        iCalUID: 'ev-meeting@google.com',
      },
      NOW,
    )
    expect(row).toMatchObject({
      description: 'Agenda:\n1. Mocks\nhttps://zoom.us/j/999 (not the join link)',
      conferenceUrl: 'https://meet.google.com/abc-defg-hij',
      organizer: { email: 'lead@example.com', displayName: 'Team Lead', self: false },
      eventType: 'default',
      recurringEventId: 'ev-meeting',
      icalUid: 'ev-meeting@google.com',
      responseStatus: 'tentative',
    })
    expect(row.attendees).toEqual([
      { email: 'lead@example.com', displayName: 'Team Lead', responseStatus: 'accepted', organizer: true, self: false, optional: false },
      { email: 'me@example.com', displayName: null, responseStatus: 'tentative', organizer: false, self: true, optional: false },
      { email: 'pm@example.com', displayName: 'PM', responseStatus: 'needsAction', organizer: false, self: false, optional: true },
    ])
  })

  it('falls back to the video entry point of a non-Meet conference and never scans text', () => {
    const zoom = mapEvent(
      CAL,
      {
        id: 'ev-zoom',
        description: 'Join at https://meet.google.com/not-this-one',
        location: 'https://zoom.us/j/111',
        start: { dateTime: '2026-11-09T17:00:00Z' },
        end: { dateTime: '2026-11-09T18:00:00Z' },
        conferenceData: {
          entryPoints: [
            { entryPointType: 'more', uri: 'https://zoom.us/more' },
            { entryPointType: 'video', uri: 'https://zoom.us/j/123456' },
          ],
        },
      },
      NOW,
    )
    expect(zoom.conferenceUrl).toBe('https://zoom.us/j/123456')

    const textOnly = mapEvent(
      CAL,
      { id: 'ev-text', description: 'https://zoom.us/j/222', location: 'https://meet.google.com/xyz', start: { dateTime: '2026-11-09T17:00:00Z' } },
      NOW,
    )
    expect(textOnly.conferenceUrl).toBeNull()
  })

  it('stores null rather than an empty list when Google sends no attendees or organizer', () => {
    const row = mapEvent(CAL, allDay, NOW)
    expect(row.attendees).toBeNull()
    expect(row.organizer).toBeNull()
    expect(row.description).toBeNull()
  })

  it('marks all-day events and uses UTC midnight for their dates', () => {
    const row = mapEvent(CAL, allDay, NOW)
    expect(row.allDay).toBe(true)
    expect(row.startAt).toEqual(new Date('2026-11-10T00:00:00Z'))
    expect(row.endAt).toEqual(new Date('2026-11-12T00:00:00Z'))
    expect(row.responseStatus).toBeNull()
    expect(row.deletedAt).toBeNull()
  })

  it('turns cancelled events into tombstones', () => {
    const row = mapEvent(CAL, cancelled, NOW)
    expect(row.status).toBe('cancelled')
    expect(row.deletedAt).toEqual(NOW)
    expect(row.startAt).toBeNull()
    expect(row.endAt).toBeNull()
    expect(row.summary).toBeNull()
  })

  it("keeps the user's own response status and transparency", () => {
    const row = mapEvent(CAL, declined, NOW)
    expect(row.responseStatus).toBe('declined')
    expect(row.transparency).toBe('transparent')
    expect(row.deletedAt).toBeNull()
  })

  it('uses the server time as updatedAt so sync cursors pick the row up', () => {
    expect(mapEvent(CAL, timed, NOW).updatedAt).toEqual(NOW)
  })
})
