import { describe, expect, it } from 'vitest'
import type { GoogleCalendarListEntry } from '../src/google/client.js'
import { selectedByDefault } from '../src/google/sync.js'

function entry(id: string, accessRole: string, extra: Partial<GoogleCalendarListEntry> = {}): GoogleCalendarListEntry {
  return { id, accessRole, ...extra }
}

describe('selectedByDefault', () => {
  it('selects the account’s own primary calendar and writable group calendars', () => {
    expect(selectedByDefault(entry('me@example.com', 'owner', { primary: true }))).toBe(true)
    expect(selectedByDefault(entry('abc123@group.calendar.google.com', 'owner'))).toBe(true)
    expect(selectedByDefault(entry('family@group.calendar.google.com', 'writer'))).toBe(true)
  })

  it('leaves other people’s calendars off even when they granted owner access', () => {
    expect(selectedByDefault(entry('coworker@example.com', 'owner'))).toBe(false)
    expect(selectedByDefault(entry('coworker@example.com', 'writer'))).toBe(false)
    expect(selectedByDefault(entry('boss@example.com', 'reader'))).toBe(false)
  })

  it('leaves read-only, holiday, subscription, and resource calendars off', () => {
    expect(selectedByDefault(entry('shared@group.calendar.google.com', 'reader'))).toBe(false)
    expect(selectedByDefault(entry('en.usa#holiday@group.v.calendar.google.com', 'reader'))).toBe(false)
    expect(selectedByDefault(entry('feed@import.calendar.google.com', 'reader'))).toBe(false)
    expect(selectedByDefault(entry('room-4a@resource.calendar.google.com', 'writer'))).toBe(false)
  })
})
