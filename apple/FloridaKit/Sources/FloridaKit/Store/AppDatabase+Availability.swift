import Foundation
import GRDB

extension AppDatabase {
    public func availabilityEvents(in range: Range<Date>, calendar: Calendar) throws -> [CalendarEvent] {
        try writer.read { db in try Self.availabilityEvents(db, in: range, calendar: calendar) }
    }

    public func observeAvailabilityEvents(
        in range: Range<Date>, calendar: Calendar
    ) -> AsyncValueObservation<[CalendarEvent]> {
        observe { db in try Self.availabilityEvents(db, in: range, calendar: calendar) }
    }

    private static func availabilityEvents(_ db: Database, in range: Range<Date>, calendar: Calendar) throws -> [CalendarEvent] {
        let allDay = AllDayDate.storedRange(overlapping: range, calendar: calendar)
        return try CalendarEvent.fetchAll(db, sql: """
            SELECT event.* FROM event
            JOIN calendar ON calendar.id = event.calendarId
            WHERE calendar.blocksScheduling
              AND event.deletedAt IS NULL
              AND event.status <> 'cancelled'
              AND (event.responseStatus IS NULL OR event.responseStatus <> 'declined')
              AND event.startAt IS NOT NULL AND event.endAt IS NOT NULL
              AND ((event.allDay = 0 AND event.startAt < ? AND event.endAt > ?)
                OR (event.allDay = 1 AND event.startAt < ? AND event.endAt > ?))
            ORDER BY event.startAt, event.id
            """, arguments: [range.upperBound, range.lowerBound, allDay.upperBound, allDay.lowerBound])
    }
}
