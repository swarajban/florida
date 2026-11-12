import Foundation
import GRDB

extension AppDatabase {
    public func setEventBlocksDay(id: String, blocksDay: Bool?, now: Date = Date()) throws {
        try writer.write { db in
            guard var event = try CalendarEvent.fetchOne(db, key: id),
                  event.deletedAt == nil, event.status != "cancelled" else { return }
            guard event.allDay else { throw WriteError.eventNotAllDay(id: id) }
            let pending = try PendingWrite.filter(Column("entity") == "event" && Column("entityId") == id).fetchOne(db)
            guard pending?.op != .delete else { return }
            event.blocksDay = blocksDay
            event.updatedAt = now
            let body: Data
            let op: PendingWrite.Op
            if pending?.op == .put, let queuedBody = pending?.body {
                var write = try JSONCoding.decoder.decode(EventWrite.self, from: queuedBody)
                write.blocksDay = blocksDay
                body = try JSONCoding.encoder.encode(write)
                op = .put
            } else if event.googleId.isEmpty {
                guard let write = EventWrite(event) else { throw WriteError.eventWithoutTimes(id: id) }
                body = try JSONCoding.encoder.encode(write)
                op = .put
            } else {
                let value: Any = blocksDay.map { $0 as Any } ?? NSNull()
                body = try JSONSerialization.data(withJSONObject: ["blocksDay": value], options: [.sortedKeys])
                op = .patch
            }
            try event.save(db)
            try Self.enqueue(db, entity: .event, id: id, op: op, body: body, now: now)
        }
    }
}
