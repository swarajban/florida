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
    { responseStatus: 'declined' },
    { self: true, responseStatus: 'accepted' },
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
      updatedAt: NOW,
      deletedAt: null,
    })
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
