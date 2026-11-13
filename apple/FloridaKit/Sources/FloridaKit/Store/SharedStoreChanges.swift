import Foundation
import GRDB
#if canImport(Darwin)
import notify
#endif

final class SharedStoreChanges: @unchecked Sendable {
    private let writer: any DatabaseWriter
    private let name: String
    #if canImport(Darwin)
    private var token: Int32?
    #else
    private var token: (any NSObjectProtocol)?
    #endif
    private var dataVersion: Int?

    init(writer: any DatabaseWriter, path: String) {
        self.writer = writer
        name = Self.notificationName(for: path)
        writer.writeWithoutTransaction { db in dataVersion = try? Int.fetchOne(db, sql: "PRAGMA data_version") }
        writer.add(transactionObserver: CommitSignal(name: name), extent: .databaseLifetime)
        #if canImport(Darwin)
        var registered: Int32 = 0
        if notify_register_dispatch(name, &registered, .global(qos: .utility), { [weak self] _ in self?.refresh() }) == NOTIFY_STATUS_OK {
            token = registered
        }
        #else
        token = NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
            self?.refresh()
        }
        #endif
        refresh()
    }

    static func notificationName(for path: String) -> String {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let hash = canonical.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return "com.swarajban.florida.store.\(String(hash, radix: 16))"
    }

    deinit {
        #if canImport(Darwin)
        if let token { notify_cancel(token) }
        #else
        if let token { NotificationCenter.default.removeObserver(token) }
        #endif
    }

    func refresh() {
        writer.asyncWriteWithoutTransaction { [self] db in
            do {
                let version = try Int.fetchOne(db, sql: "PRAGMA data_version")
                guard version != dataVersion else { return }
                try db.inTransaction(.deferred) {
                    try db.notifyChanges(in: .fullDatabase)
                    return .commit
                }
                dataVersion = version
            } catch { }
        }
    }

    private final class CommitSignal: TransactionObserver {
        let name: String
        var changed = false

        init(name: String) { self.name = name }

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
        func databaseDidChange(with event: DatabaseEvent) { changed = true }
        func databaseDidCommit(_ db: Database) {
            guard changed else { return }
            changed = false
            #if canImport(Darwin)
            notify_post(name)
            #else
            NotificationCenter.default.post(name: Notification.Name(name), object: nil)
            #endif
        }
        func databaseDidRollback(_ db: Database) { changed = false }
    }
}
