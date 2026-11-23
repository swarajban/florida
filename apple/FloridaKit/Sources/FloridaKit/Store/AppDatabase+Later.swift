import Foundation
import GRDB

extension AppDatabase {
    public enum LaterWriteError: Error, Sendable {
        case invalidLink, itemNoLongerExists
    }

    public func laterItems(status: LaterItem.Status? = .queue) throws -> [LaterItem] {
        try writer.read { db in
            let live = LaterItem.filter(Column("deletedAt") == nil)
            let request = switch status {
            case .queue: live.filter(Column("archivedAt") == nil && Column("readAt") == nil)
            case .read: live.filter(Column("archivedAt") == nil && Column("readAt") != nil)
            case .archived: live.filter(Column("archivedAt") != nil)
            case nil: live
            }
            return try request.order(Column("savedAt"), Column("id")).fetchAll(db)
        }
    }

    @discardableResult
    public func saveLater(
        url: String, title: String? = nil, kind: LaterItem.Kind, source: LaterItem.Source = .manual,
        captureID: UUID = UUID(), now: Date = Date()
    ) throws -> LaterItem {
        let id = captureID.uuidString.lowercased()
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = LaterItem.webURL(url),
              var canonical = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
              let host = canonical.host?.lowercased(), (title?.utf16.count ?? 0) <= 200
        else { throw LaterWriteError.invalidLink }
        canonical.host = host
        canonical.fragment = nil
        return try writer.write { [canonicalUrl = canonical.string ?? url] db in
            if let item = try LaterItem.fetchOne(db, id: id) {
                guard item.deletedAt == nil, item.url == url else { throw LaterWriteError.itemNoLongerExists }
                return item
            }
            let item = LaterItem(id: id, url: url, canonicalUrl: canonicalUrl,
                title: title.flatMap { $0.isEmpty ? nil : $0 } ?? host, site: host,
                kind: kind, savedAt: now, source: source, updatedAt: now)
            try item.insert(db)
            try db.execute(sql: "INSERT INTO syncState (key, value) VALUES (?, '1')", arguments: ["later-unconfirmed:\(id)"])
            try Self.enqueueLaterCapture(db, item: item, state: nil, now: now)
            return item
        }
    }

    public func setLaterState(id: String, action: LaterItem.Action, now: Date = Date()) throws {
        try writer.write { db in
            guard var item = try LaterItem.fetchOne(db, id: id), item.deletedAt == nil
            else { throw LaterWriteError.itemNoLongerExists }
            item.apply(action, at: now)
            try item.update(db)
            let state = LaterState(action: action, at: now)
            if try Self.laterCreationUnconfirmed(db, id: id) {
                try Self.enqueueLaterCapture(db, item: item, state: state, now: now)
            } else {
                try Self.enqueue(db, entity: .laterItem, id: id, op: .patch, body: JSONCoding.encoder.encode(state), now: now)
            }
        }
    }

    static func laterCreationUnconfirmed(_ db: Database, id: String) throws -> Bool {
        try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: ["later-unconfirmed:\(id)"]) != nil
    }

    static func clearLaterCreation(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: ["later-unconfirmed:\(id)"])
    }

    public func deleteLater(id: String, now: Date = Date()) throws {
        try writer.write { db in
            guard var item = try LaterItem.fetchOne(db, id: id), item.deletedAt == nil else { return }
            item.deletedAt = now
            item.updatedAt = now
            try item.update(db)
            try Self.enqueue(db, entity: .laterItem, id: id, op: .delete, body: nil, now: now)
        }
    }

    private struct LaterState: Encodable {
        let action: LaterItem.Action
        let at: Date
    }

    private struct LaterCapture: Encodable {
        let url: String
        let title: String
        let kind: LaterItem.Kind
        let source: LaterItem.Source
        let savedAt: Date
        let state: LaterState?
    }

    private static func enqueueLaterCapture(_ db: Database, item: LaterItem, state: LaterState?, now: Date) throws {
        let capture = LaterCapture(url: item.url, title: item.title, kind: item.kind,
            source: item.source, savedAt: item.savedAt, state: state)
        try enqueue(db, entity: .laterItem, id: item.id, op: .put, body: JSONCoding.encoder.encode(capture), now: now)
    }
}
