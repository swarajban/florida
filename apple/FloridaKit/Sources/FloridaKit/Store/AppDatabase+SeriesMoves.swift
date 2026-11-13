import Foundation
import GRDB

extension AppDatabase {
    struct SeriesMoveTimes: Codable {
        var id: String
        var start: Date?
        var end: Date?
        var movedStart: Date?
        var movedEnd: Date?
    }

    static func seriesMoveTimes(_ db: Database, id: String) throws -> [SeriesMoveTimes] {
        guard let value = try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: ["series-move:\(id)"]),
              let data = value.data(using: .utf8) else { return [] }
        return try JSONCoding.decoder.decode([SeriesMoveTimes].self, from: data)
    }

    static func storeSeriesMoveTimes(_ db: Database, id: String, times: [SeriesMoveTimes]) throws {
        let value = String(decoding: try JSONCoding.encoder.encode(times), as: UTF8.self)
        try db.execute(sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES (?, ?)", arguments: ["series-move:\(id)", value])
    }

    static func restoreSeriesMove(_ db: Database, id: String) throws {
        for times in try seriesMoveTimes(db, id: id) {
            guard var event = try CalendarEvent.fetchOne(db, id: times.id), event.deletedAt == nil,
                  event.startAt == times.movedStart, event.endAt == times.movedEnd,
                  try PendingWrite.filter(Column("entity") == "event" && Column("entityId") == times.id).fetchCount(db) == 0
            else { continue }
            event.startAt = times.start
            event.endAt = times.end
            try event.update(db)
        }
        try clearSeriesMove(db, id: id)
    }

    static func rebaseSeriesMove(_ db: Database, acknowledged: PendingWrite, accepted: CalendarEvent) throws {
        guard acknowledged.op == .put, let body = acknowledged.body,
              try JSONCoding.decoder.decode(EventWrite.self, from: body).scope == .series,
              let newer = try PendingWrite.filter(Column("entity") == "event" && Column("entityId") == acknowledged.entityId).fetchOne(db),
              newer.op == .put, let newerBody = newer.body,
              let acceptedStart = accepted.startAt, let acceptedEnd = accepted.endAt else { return }
        let queued = try JSONCoding.decoder.decode(EventWrite.self, from: newerBody)
        guard queued.scope == .series else { return }
        let shift = acceptedStart.timeIntervalSince(queued.startAt)
        let length = acceptedEnd.timeIntervalSince(acceptedStart)
        var times = try seriesMoveTimes(db, id: acknowledged.entityId)
        for index in times.indices {
            guard let movedStart = times[index].movedStart else { continue }
            let start = movedStart.addingTimeInterval(shift)
            times[index].start = start
            times[index].end = start.addingTimeInterval(length)
        }
        try storeSeriesMoveTimes(db, id: acknowledged.entityId, times: times)
    }

    static func clearSeriesMove(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: ["series-move:\(id)"])
    }
}
