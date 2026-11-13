import { and, eq, isNull, sql } from 'drizzle-orm'
import type { Db } from '../db/client.js'
import { calendars, events, googleAccounts } from '../db/schema.js'
import { judgeAllDayEvent } from './all-day-judgment.js'
import type { AllDayAccountProfile, AllDayJudgmentCalendar, AllDayJudgmentEvent } from './all-day-judgment.js'
import { mapEvent } from './client.js'
import type { GoogleEvent } from './client.js'

interface ProfileMetadata {
  organizer?: { email?: string; displayName?: string | null } | null
  attendees?: readonly { email?: string; displayName?: string | null }[] | null
}

export async function learnAccountProfiles(db: Db, items: readonly ProfileMetadata[], now: Date, loaded?: AllDayAccountProfile[]) {
  const profiles = loaded ?? await db.select({ id: googleAccounts.id, email: googleAccounts.email, displayName: googleAccounts.displayName }).from(googleAccounts)
  let learned = false
  for (const item of items) {
    for (const person of [item.organizer, ...(item.attendees ?? [])]) {
      const name = person?.displayName?.trim()
      if (!name || !person?.email) continue
      const email = person.email.toLowerCase()
      const profile = profiles.find((p) => p.email.toLowerCase() === email)
      if (profile === undefined || profile.displayName !== null) continue
      const [updated] = await db.update(googleAccounts).set({ displayName: name, updatedAt: now })
        .where(and(eq(googleAccounts.id, profile.id), isNull(googleAccounts.displayName))).returning()
      const stored = updated ?? (await db.select({ displayName: googleAccounts.displayName }).from(googleAccounts)
        .where(eq(googleAccounts.id, profile.id)))[0]
      if (stored?.displayName != null) {
        profile.displayName = stored.displayName
        learned = true
      }
    }
  }
  return { profiles, learned }
}

export function automaticDayFields(event: AllDayJudgmentEvent, calendar: AllDayJudgmentCalendar, profiles: readonly AllDayAccountProfile[]) {
  if (!event.allDay) return { autoBlocksDay: null, blockingReason: null }
  const judgment = judgeAllDayEvent(event, calendar, profiles)
  return { autoBlocksDay: judgment.blocks, blockingReason: judgment.reason }
}

export function judgedGoogleEvent(calendar: AllDayJudgmentCalendar & { id: string }, item: GoogleEvent, profiles: readonly AllDayAccountProfile[], now: Date) {
  const row = mapEvent(calendar.id, item, now)
  return { ...row, ...automaticDayFields(row, calendar, profiles) }
}

export async function refreshAllDayJudgments(db: Db, now: Date = new Date()): Promise<void> {
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      await db.transaction(async (tx) => {
        const { profiles } = await learnAccountProfiles(tx, [], now)
        const unidentified = profiles.filter((profile) => profile.displayName === null).map((profile) => profile.email.toLowerCase())
        if (unidentified.length > 0) {
          const metadata = await tx.select({ organizer: events.organizer, attendees: events.attendees }).from(events)
            .where(and(isNull(events.deletedAt), sql`exists (
              select 1 from jsonb_array_elements(coalesce(${events.attendees}, '[]'::jsonb) || jsonb_build_array(${events.organizer})) as person(value)
              where lower(person.value->>'email') in (${sql.join(unidentified.map((email) => sql`${email}`), sql`, `)})
                and nullif(btrim(person.value->>'displayName'), '') is not null
            )`))
          await learnAccountProfiles(tx, metadata, now, profiles)
        }
        const rows = await tx.select({ event: events, calendar: calendars }).from(events)
          .innerJoin(calendars, eq(events.calendarId, calendars.id))
          .where(and(eq(events.allDay, true), isNull(events.deletedAt)))
        for (const { event, calendar } of rows) {
          const fields = automaticDayFields(event, calendar, profiles)
          if (event.autoBlocksDay === fields.autoBlocksDay && event.blockingReason === fields.blockingReason) continue
          await tx.update(events).set({ ...fields, updatedAt: new Date(Math.max(now.getTime(), event.updatedAt.getTime() + 1)) })
            .where(and(eq(events.id, event.id), eq(events.updatedAt, event.updatedAt), isNull(events.deletedAt)))
        }
      }, { isolationLevel: 'repeatable read' })
      return
    } catch (error) {
      const cause = error instanceof Error && error.cause !== undefined ? error.cause : error
      if (attempt === 2 || typeof cause !== 'object' || cause === null || !('code' in cause) || cause.code !== '40001') throw error
    }
  }
}
