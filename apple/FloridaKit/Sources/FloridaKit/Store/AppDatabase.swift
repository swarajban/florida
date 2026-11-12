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

    /// URL of the shared store inside the App Group container; nil when this process has no
    /// container (missing entitlement or a different group id, or outside the Darwin sandbox).
    /// Extensions that must read the app's data use this rather than `defaultURL`, whose fallback
    /// would silently open an empty private store.
    public static func sharedURL(appGroup: String = Florida.appGroup) -> URL? {
        #if canImport(Darwin)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("florida.sqlite")
        #else
        return nil
        #endif
    }

    /// `sharedURL`, or a private location when there is no App Group container. Outside the
    /// Darwin sandbox (Linux tests) it falls back to a temporary directory.
    public static func defaultURL(appGroup: String = Florida.appGroup) -> URL {
        if let shared = sharedURL(appGroup: appGroup) {
            return shared
        }
        #if canImport(Darwin)
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

        migrator.registerMigration("v2") { db in
            // Event details; `attendees` and `organizer` are JSON text like `schedule.windows`.
            try db.alter(table: "event") { t in
                t.add(column: "description", .text)
                t.add(column: "conferenceUrl", .text)
                t.add(column: "attendees", .text)
                t.add(column: "organizer", .text)
                t.add(column: "eventType", .text)
                t.add(column: "recurringEventId", .text)
                t.add(column: "icalUid", .text)
            }

            // Scheduler output, replaced wholesale like `placement`.
            try db.create(table: "unscheduled") { t in
                t.primaryKey("taskId", .text)
                t.column("reason", .text).notNull()
                t.column("unplacedMinutes", .integer).notNull()
                t.column("computedAt", .datetime).notNull()
            }

            // Events already mirrored have no details yet; the next pull fetches every row again
            // so they arrive without waiting for each event to change.
            try db.execute(sql: "DELETE FROM syncState WHERE key = 'cursor'")
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "task") { t in
                t.add(column: "recurrence", .text)
                t.add(column: "recurrenceSeriesId", .text)
                t.add(column: "recurrenceDate", .text)
                t.add(column: "recurrenceRevision", .text)
            }
            // Existing tasks need their series metadata even if they have not changed recently.
            try db.execute(sql: "DELETE FROM syncState WHERE key = 'cursor'")
        }

        migrator.registerMigration("v4") { db in
            // Where a task can be done, and which side of life a category belongs to.
            try db.alter(table: "task") { t in
                t.add(column: "context", .text).notNull().defaults(to: TaskContext.computer.rawValue)
            }
            try db.alter(table: "category") { t in
                t.add(column: "area", .text)
            }

            // The weekly routine; `days` and `allows` are JSON text like `schedule.windows`.
            try db.create(table: "routineBlock") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("days", .text).notNull()
                t.column("start", .text).notNull()
                t.column("end", .text).notNull()
                t.column("allows", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            // The server's single settings row, replaced on every sync.
            try db.create(table: "userSettings") { t in
                t.primaryKey("id", .text)
                t.column("timeZone", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Contexts, areas and the routine arrive for rows that have not changed recently.
            try db.execute(sql: "DELETE FROM syncState WHERE key = 'cursor'")
        }

        migrator.registerMigration("v5") { db in
            // Blocks the user might work but does not count on (an evening).
            try db.alter(table: "routineBlock") { t in
                t.add(column: "optional", .boolean).notNull().defaults(to: false)
            }

            // Scheduler suggestions for those blocks, replaced wholesale like `placement`.
            try db.create(table: "optionalPlacement") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().indexed()
                t.column("blockId", .text).notNull()
                t.column("startAt", .datetime).notNull()
                t.column("endAt", .datetime).notNull()
                t.column("computedAt", .datetime).notNull()
            }

            // A block stored by the previous version has no `optional` yet; fetch the routine again.
            try db.execute(sql: "DELETE FROM syncState WHERE key = 'cursor'")
        }

        migrator.registerMigration("v6") { db in
            // Projects, and which of them a task belongs to.
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("status", .text).notNull()
                t.column("categoryId", .text)
                t.column("notes", .text)
                t.column("nextStep", .text)
                t.column("parallel", .boolean).notNull()
                t.column("weeklyMinutes", .integer)
                t.column("sortOrder", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.alter(table: "task") { t in
                t.add(column: "projectId", .text)
                t.add(column: "attention", .text)
            }

            // Blocks worked side by side, and a commitment's alternate slots (JSON text like `days`).
            try db.alter(table: "placement") { t in
                t.add(column: "lane", .integer)
            }
            try db.alter(table: "routineBlock") { t in
                t.add(column: "alternates", .text)
            }

            // Single dates that depart from the routine, keyed by local date.
            try db.create(table: "dayOverride") { t in
                t.primaryKey("date", .text)
                t.column("kind", .text).notNull()
                t.column("note", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            // Scheduler output, replaced wholesale like `placement`. `planSummary` holds one row
            // whose `missed` and `capacity` are JSON text.
            try db.create(table: "projectPlacement") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                t.column("weekOf", .text).notNull()
                t.column("startAt", .datetime).notNull().indexed()
                t.column("endAt", .datetime).notNull()
                t.column("lane", .integer)
                t.column("computedAt", .datetime).notNull()
            }
            try db.create(table: "routineOccurrence") { t in
                t.primaryKey("id", .text)
                t.column("blockId", .text).notNull()
                t.column("startAt", .datetime).notNull().indexed()
                t.column("endAt", .datetime).notNull()
                t.column("computedAt", .datetime).notNull()
            }
            try db.create(table: "planSummary") { t in
                t.column("missed", .text).notNull()
                t.column("capacity", .text).notNull()
            }

            // The newest daily brief and weekly review, replaced on every sync.
            try db.create(table: "brief") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("date", .text).notNull()
                t.column("headline", .text).notNull()
                t.column("body", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Tasks and routine blocks stored by the previous version lack the new columns.
            try db.execute(sql: "DELETE FROM syncState WHERE key = 'cursor'")
        }

        migrator.registerMigration("v7-calendar-blocking") { db in
            try db.alter(table: "calendar") { t in
                t.add(column: "blocksScheduling", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v8-event-blocks-day") { db in
            try db.alter(table: "event") { t in
                t.add(column: "blocksDay", .boolean)
            }
            try db.execute(sql: "DELETE FROM syncState WHERE key = 'cursor'")
        }

        return migrator
    }
}
