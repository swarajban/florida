import Foundation
import GRDB

extension AppDatabase {
    /// Sets and queues a flag in one transaction so a pull cannot revert an offline toggle.
    public func setCalendarSelected(id: String, selected: Bool, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE calendar SET selected = ?, updatedAt = ? WHERE id = ?",
                arguments: [selected, now, id])
            try Self.enqueueCalendarPatch(db, id: id, fields: ["selected": selected], now: now)
        }
    }

    public func setCalendarBlocksScheduling(id: String, blocksScheduling: Bool, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE calendar SET blocksScheduling = ?, updatedAt = ? WHERE id = ?",
                arguments: [blocksScheduling, now, id])
            try Self.enqueueCalendarPatch(db, id: id, fields: ["blocksScheduling": blocksScheduling], now: now)
        }
    }

    private static func enqueueCalendarPatch(_ db: Database, id: String, fields: [String: Bool], now: Date) throws {
        guard try CalendarInfo.fetchOne(db, id: id) != nil else { return }
        let pending = try PendingWrite.filter(Column("entity") == "calendar" && Column("entityId") == id).fetchOne(db)
        var merged: [String: Bool] = [:]
        if let body = pending?.body {
            merged = try JSONCoding.decoder.decode([String: Bool].self, from: body)
        }
        merged.merge(fields) { _, new in new }
        try enqueue(db, entity: .calendar, id: id, op: .patch, body: JSONCoding.encoder.encode(merged), now: now)
    }

    func acceptCalendarPatch(id: String, patch: CalendarPatch, scheduling: SchedulingResult) throws {
        try writer.write { db in
            guard var calendar = try CalendarInfo.fetchOne(db, id: id) else { return }
            let pending = try PendingWrite.filter(Column("entity") == "calendar" && Column("entityId") == id).fetchOne(db)
            let fields = try pending?.body.map { try JSONCoding.decoder.decode([String: Bool].self, from: $0) } ?? [:]
            if fields["selected"] == nil, let selected = patch.selected { calendar.selected = selected }
            if fields["blocksScheduling"] == nil, let blocks = patch.blocksScheduling { calendar.blocksScheduling = blocks }
            try calendar.save(db)
            try Self.replaceSchedulerOutput(db, with: scheduling, computedAt: Date())
        }
    }
}
