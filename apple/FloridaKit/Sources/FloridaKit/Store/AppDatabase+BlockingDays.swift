import Foundation
import GRDB

extension AppDatabase {
    public func blockingAllDayEvents(
        in range: Range<Date>, calendar: Calendar = .autoupdatingCurrent
    ) throws -> [CalendarEvent] {
        try writer.read { try Self.blockingAllDayEvents($0, in: range, calendar: calendar) }
    }

    public func observeBlockingAllDayEvents(
        in range: Range<Date>, calendar: Calendar = .autoupdatingCurrent
    ) -> AsyncValueObservation<[CalendarEvent]> {
        observe { try Self.blockingAllDayEvents($0, in: range, calendar: calendar) }
    }

    static func blockingAllDayEvents(_ db: Database, in range: Range<Date>, calendar: Calendar) throws -> [CalendarEvent] {
        let stored = AllDayDate.storedRange(overlapping: range, calendar: calendar)
        return try CalendarEvent.fetchAll(db, sql: """
            SELECT event.* FROM event
            JOIN calendar ON calendar.id = event.calendarId
            WHERE calendar.blocksScheduling AND event.allDay = 1
              AND event.startAt < ? AND event.endAt > ?
            ORDER BY event.startAt, event.id
            """, arguments: [stored.upperBound, stored.lowerBound])
            .filter {
                AllDayBlocking.isEffective($0, calendarBlocksScheduling: true)
                    && AllDayBlocking.protectedDays(for: $0, calendar: calendar)?.overlaps(range) == true
            }
    }
}
