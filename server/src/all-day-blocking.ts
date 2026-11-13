import { DAY } from '@florida/scheduler'
import type { EventRow } from './db/schema.js'

type AllDayEvent = Pick<EventRow, 'allDay' | 'autoBlocksDay' | 'blockingReason' | 'startAt' | 'endAt'>

export function automaticTripEnd(event: AllDayEvent): Date | null {
  const { startAt, endAt } = event
  if (event.allDay && event.autoBlocksDay === true && event.blockingReason === 'Your trip'
    && startAt !== null && endAt !== null && endAt.getTime() - startAt.getTime() >= 2 * DAY) {
    return new Date(endAt.getTime() - DAY)
  }
  return endAt
}

export function automaticDayReason(event: AllDayEvent): string | null {
  return automaticTripEnd(event)?.getTime() !== event.endAt?.getTime()
    ? `${event.blockingReason} · last day open` : event.blockingReason
}
