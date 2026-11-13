import Foundation
import GRDB

extension AppDatabase {
    public struct EventSeriesMember: Sendable {
        public let id: String
        public let calendarId: String
        public let recurringEventId: String?
        public let allDay: Bool
        public let status: String
        public let startAt: Date?
        public let endAt: Date?

        init(_ event: CalendarEvent) {
            id = event.id
            calendarId = event.calendarId
            recurringEventId = event.recurringEventId
            allDay = event.allDay
            status = event.status
            startAt = event.startAt
            endAt = event.endAt
        }
    }

    public struct EventMutation: Sendable {
        public let from: DateInterval
        public let to: DateInterval
        public let expectedSeries: [EventSeriesMember]?

        init(from: DateInterval, to: DateInterval, expectedSeries: [EventSeriesMember]? = nil) {
            self.from = from
            self.to = to
            self.expectedSeries = expectedSeries
        }
    }

    public func moveEvent(id: String, toStart start: Date, series: Bool = false, now: Date = Date()) throws -> EventMutation {
        try writer.write { db in
            guard var live = try CalendarEvent.fetchOne(db, id: id), live.deletedAt == nil,
                  live.status != "cancelled" else { throw WriteError.eventNoLongerExists }
            guard let oldStart = live.startAt, let oldEnd = live.endAt, oldEnd > oldStart else {
                throw WriteError.eventWithoutTimes(id: id)
            }
            let end = start.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
            if series {
                return try Self.moveEventSeries(instanceId: id, start: start, end: end, in: db, now: now)
            }
            live.startAt = start
            live.endAt = end
            try Self.saveEvent(live, recurrence: nil, in: db, now: now)
            return EventMutation(from: DateInterval(start: oldStart, end: oldEnd), to: DateInterval(start: start, end: end))
        }
    }

    public func undoEventMove(
        id: String, expected: DateInterval, restoring: DateInterval, series: Bool = false,
        expectedSeries: [EventSeriesMember]? = nil, now: Date = Date()
    ) throws -> Bool {
        try writer.write { db in
            guard var live = try CalendarEvent.fetchOne(db, id: id), live.deletedAt == nil,
                  live.status != "cancelled", let start = live.startAt, let end = live.endAt,
                  abs(start.timeIntervalSince(expected.start)) < 1,
                  abs(end.timeIntervalSince(expected.end)) < 1 else { return false }
            if series {
                let members = try Self.eventSeriesMembers(of: live, in: db)
                if let expectedSeries {
                    guard members.count == expectedSeries.count,
                          zip(members, expectedSeries).allSatisfy({ live, expected in
                              live.id == expected.id && live.calendarId == expected.calendarId
                                  && live.recurringEventId == expected.recurringEventId && live.allDay == expected.allDay
                                  && live.status == expected.status && Self.sameEventTime(live.startAt, expected.startAt)
                                  && Self.sameEventTime(live.endAt, expected.endAt)
                          }) else { return false }
                } else if members.count != 1 {
                    return false
                }
                _ = try Self.moveEventSeries(instanceId: id, start: restoring.start, end: restoring.end, in: db, now: now)
            } else {
                live.startAt = restoring.start
                live.endAt = restoring.end
                try Self.saveEvent(live, recurrence: nil, in: db, now: now)
            }
            return true
        }
    }

    static func eventSeriesMembers(of instance: CalendarEvent, in db: Database) throws -> [EventSeriesMember] {
        var members = [instance]
        if let series = instance.recurringEventId {
            members += try CalendarEvent
                .filter(Column("calendarId") == instance.calendarId && Column("recurringEventId") == series)
                .filter(Column("id") != instance.id && Column("deletedAt") == nil && Column("allDay") == false)
                .fetchAll(db)
        }
        return members.sorted { $0.id < $1.id }.map(EventSeriesMember.init)
    }

    private static func sameEventTime(_ first: Date?, _ second: Date?) -> Bool {
        switch (first, second) {
        case (nil, nil): true
        case (let first?, let second?): abs(first.timeIntervalSince(second)) < 1
        default: false
        }
    }
}
