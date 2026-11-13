import Foundation
import GRDB

extension AppDatabase {
    public struct EventMutation: Sendable {
        public let from: DateInterval
        public let to: DateInterval
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
        id: String, expected: DateInterval, restoring: DateInterval, series: Bool = false, now: Date = Date()
    ) throws -> Bool {
        try writer.write { db in
            guard var live = try CalendarEvent.fetchOne(db, id: id), live.deletedAt == nil,
                  live.status != "cancelled", let start = live.startAt, let end = live.endAt,
                  abs(start.timeIntervalSince(expected.start)) < 1,
                  abs(end.timeIntervalSince(expected.end)) < 1 else { return false }
            if series {
                _ = try Self.moveEventSeries(instanceId: id, start: restoring.start, end: restoring.end, in: db, now: now)
            } else {
                live.startAt = restoring.start
                live.endAt = restoring.end
                try Self.saveEvent(live, recurrence: nil, in: db, now: now)
            }
            return true
        }
    }
}
