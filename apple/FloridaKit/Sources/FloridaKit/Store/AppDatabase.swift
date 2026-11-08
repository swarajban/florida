import Foundation
import GRDB

/// The local SQLite store shared by the apps and the widgets. Holds a mirror of the server's
/// tables plus the queue of local writes waiting to be pushed.
public final class AppDatabase: Sendable {
    /// `DatabasePool` for on-disk stores, `DatabaseQueue` for in-memory ones.
    public let writer: any DatabaseWriter

    /// Opens (or creates) the store at `path`, creating parent directories, in WAL mode, migrated.
    public init(path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // DatabasePool switches the file to WAL mode when it opens it.
        let pool = try DatabasePool(path: path)
        try Self.migrator.migrate(pool)
        writer = pool
    }

    init(writer: any DatabaseWriter) throws {
        try Self.migrator.migrate(writer)
        self.writer = writer
    }

    /// A fresh, migrated, private in-memory store; for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue())
    }

    /// URL of the shared store inside the App Group container. Outside the Darwin sandbox (Linux
    /// tests) it falls back to a temporary directory.
    public static func defaultURL(appGroup: String = Florida.appGroup) -> URL {
        #if canImport(Darwin)
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return container.appendingPathComponent("florida.sqlite")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Florida/florida.sqlite")
        #else
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(appGroup)/florida.sqlite")
        #endif
    }

    // MARK: - Observation

    /// An asynchronous sequence that yields `fetch`'s result now and again whenever the database
    /// regions it read change.
    public func observe<T: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncValueObservation<T> {
        ValueObservation.tracking(fetch).values(in: writer)
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.create(table: "schedule") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("timeZone", .text).notNull()
                t.column("windows", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            try db.create(table: "category") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("color", .text)
                t.column("scheduleId", .text).notNull()
                t.column("sortOrder", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            try db.create(table: "task") { t in
                t.primaryKey("id", .text)
                t.column("categoryId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("notes", .text)
                t.column("durationMinutes", .integer).notNull()
                t.column("minChunkMinutes", .integer)
                t.column("priority", .text).notNull()
                t.column("deadlineType", .text).notNull()
                t.column("dueAt", .datetime)
                t.column("startAt", .datetime)
                t.column("scheduleId", .text)
                t.column("pinnedStart", .datetime)
                t.column("completedMinutes", .integer).notNull()
                t.column("completedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(indexOn: "task", columns: ["categoryId"])
            try db.create(indexOn: "task", columns: ["completedAt"])

            try db.create(table: "placement") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull()
                t.column("startAt", .datetime).notNull()
                t.column("endAt", .datetime).notNull()
                t.column("pinned", .boolean).notNull()
                t.column("computedAt", .datetime).notNull()
            }
            try db.create(indexOn: "placement", columns: ["startAt"])

            try db.create(table: "event") { t in
                t.primaryKey("id", .text)
                t.column("calendarId", .text).notNull()
                t.column("googleId", .text).notNull()
                t.column("status", .text).notNull()
                t.column("summary", .text)
                t.column("location", .text)
                t.column("startAt", .datetime)
                t.column("endAt", .datetime)
                t.column("allDay", .boolean).notNull()
                t.column("transparency", .text)
                t.column("responseStatus", .text)
                t.column("htmlLink", .text)
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(indexOn: "event", columns: ["calendarId"])
            try db.create(indexOn: "event", columns: ["startAt"])

            try db.create(table: "googleAccount") { t in
                t.primaryKey("id", .text)
                t.column("email", .text).notNull()
                t.column("label", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "calendar") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull()
                t.column("googleId", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("color", .text)
                t.column("accessRole", .text).notNull()
                t.column("selected", .boolean).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "syncState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }

            try db.create(table: "pendingWrite") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("entity", .text).notNull()
                t.column("entityId", .text).notNull()
                t.column("op", .text).notNull()
                t.column("body", .blob)
                t.column("createdAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
