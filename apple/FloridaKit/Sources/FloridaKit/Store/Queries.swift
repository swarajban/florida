import Foundation
import GRDB

// MARK: - Reads

extension AppDatabase {
    /// Live schedules, by name.
    public func schedules() throws -> [Schedule] {
        try writer.read { db in
            try Schedule.filter(Column("deletedAt") == nil).order(Column("name")).fetchAll(db)
        }
    }

    /// Live categories, by `sortOrder` then name.
    public func categories() throws -> [Category] {
        try writer.read { db in
            try Category.filter(Column("deletedAt") == nil).order(Column("sortOrder"), Column("name")).fetchAll(db)
        }
    }

    public func accounts() throws -> [GoogleAccount] {
        try writer.read { db in try GoogleAccount.order(Column("email")).fetchAll(db) }
    }

    public func calendars() throws -> [CalendarInfo] {
        try writer.read { db in try CalendarInfo.order(Column("accountId"), Column("summary")).fetchAll(db) }
    }

    /// Tasks that are neither deleted nor completed: asap first, then earlier due dates (tasks
    /// without a due date last), then oldest first.
    public func openTasks() throws -> [TaskItem] {
        try writer.read { db in
            try TaskItem.fetchAll(db, sql: """
                SELECT * FROM task
                WHERE deletedAt IS NULL AND completedAt IS NULL
                ORDER BY \(Self.priorityRankSQL), dueAt IS NULL, dueAt, createdAt
                """)
        }
    }

    /// Live tasks of one category (completed ones included), in the same order as `openTasks()`.
    public func tasks(inCategory categoryId: String) throws -> [TaskItem] {
        try writer.read { db in
            try TaskItem.fetchAll(db, sql: """
                SELECT * FROM task
                WHERE deletedAt IS NULL AND categoryId = ?
                ORDER BY \(Self.priorityRankSQL), dueAt IS NULL, dueAt, createdAt
                """, arguments: [categoryId])
        }
    }

    public func task(id: String) throws -> TaskItem? {
        try writer.read { db in try TaskItem.fetchOne(db, id: id) }
    }

    /// Placements overlapping `range`, by start.
    public func placements(in range: Range<Date>) throws -> [Placement] {
        try writer.read { db in try Self.placements(db, in: range) }
    }

    /// Visible events (live, not cancelled, not declined) from selected calendars that overlap
    /// `range`, by start. All-day events are compared with the instants the server stored.
    public func events(in range: Range<Date>) throws -> [CalendarEvent] {
        try writer.read { db in try Self.events(db, in: range) }
    }

    /// Placements overlapping `range` joined to their tasks, by start. Placements whose task is
    /// missing locally are left out.
    public func scheduledBlocks(in range: Range<Date>) throws -> [ScheduledBlock] {
        try writer.read { db in try Self.scheduledBlocks(db, in: range) }
    }

    /// Every placement, grouped by task id and ordered by start within each task. The table only
    /// holds the scheduler's horizon, so the task list can derive each task's scheduled time from
    /// it without a date filter.
    public func placementsByTask() throws -> [String: [Placement]] {
        let placements = try writer.read { db in try Placement.order(Column("startAt")).fetchAll(db) }
        return Dictionary(grouping: placements, by: \.taskId)
    }

    /// Visible events and scheduled task blocks for the calendar day containing `day`.
    public func agenda(for day: Date, calendar: Calendar) throws -> DayAgenda {
        let range = Self.dayRange(containing: day, calendar: calendar)
        return try writer.read { db in try Self.agenda(db, in: range) }
    }

    /// The `since` cursor returned by the last applied `GET /api/sync`, if any.
    public func cursor() throws -> String? {
        try writer.read { db in try Self.cursor(db) }
    }

    static let priorityRankSQL = """
        CASE priority WHEN 'asap' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END
        """

    /// Start of the calendar day containing `day` up to the start of the next one.
    static func dayRange(containing day: Date, calendar: Calendar) -> Range<Date> {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start..<end
    }

    static func placements(_ db: Database, in range: Range<Date>) throws -> [Placement] {
        try Placement.fetchAll(db, sql: """
            SELECT * FROM placement
            WHERE startAt < ? AND endAt > ?
            ORDER BY startAt
            """, arguments: [range.upperBound, range.lowerBound])
    }

    static func scheduledBlocks(_ db: Database, in range: Range<Date>) throws -> [ScheduledBlock] {
        let placements = try placements(db, in: range)
        let tasks = try TaskItem.filter(ids: Set(placements.map(\.taskId))).fetchAll(db)
        let tasksById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return placements.compactMap { placement in
            tasksById[placement.taskId].map { ScheduledBlock(placement: placement, task: $0) }
        }
    }

    /// `range` must be one calendar day, as `dayRange(containing:calendar:)` returns it.
    static func agenda(_ db: Database, in range: Range<Date>) throws -> DayAgenda {
        DayAgenda(
            day: range.lowerBound,
            events: try events(db, in: range),
            placements: try scheduledBlocks(db, in: range))
    }

    static func events(_ db: Database, in range: Range<Date>) throws -> [CalendarEvent] {
        try CalendarEvent.fetchAll(db, sql: """
            SELECT event.* FROM event
            JOIN calendar ON calendar.id = event.calendarId
            WHERE calendar.selected
              AND event.deletedAt IS NULL
              AND event.status <> 'cancelled'
              AND (event.responseStatus IS NULL OR event.responseStatus <> 'declined')
              AND event.startAt IS NOT NULL AND event.endAt IS NOT NULL
              AND event.startAt < ? AND event.endAt > ?
            ORDER BY event.startAt
            """, arguments: [range.upperBound, range.lowerBound])
    }

    static func cursor(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = 'cursor'")
    }
}

// MARK: - Local writes

extension AppDatabase {
    /// Upserts the task with `updatedAt = now` and queues a `put` for the server, replacing any
    /// earlier queued write for the same task.
    public func saveTask(_ task: TaskItem, now: Date = Date()) throws {
        var task = task
        task.updatedAt = now
        let body = try JSONCoding.encoder.encode(TaskWrite(task))
        try writer.write { db in
            try task.save(db)
            try Self.enqueue(db, entity: .task, id: task.id, op: .put, body: body, now: now)
        }
    }

    /// Marks the task deleted locally and queues a `delete`, replacing any queued `put`.
    public func deleteTask(id: String, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE task SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
            try Self.enqueue(db, entity: .task, id: id, op: .delete, body: nil, now: now)
        }
    }

    /// Marks the task complete at `at` (its remaining minutes count as done).
    public func completeTask(id: String, at completedAt: Date = Date()) throws {
        guard var task = try task(id: id) else { return }
        task.completedAt = completedAt
        task.completedMinutes = task.durationMinutes
        try saveTask(task, now: completedAt)
    }

    public func reopenTask(id: String, now: Date = Date()) throws {
        guard var task = try task(id: id) else { return }
        task.completedAt = nil
        task.completedMinutes = 0
        try saveTask(task, now: now)
    }

    public func saveCategory(_ category: Category, now: Date = Date()) throws {
        var category = category
        category.updatedAt = now
        let body = try JSONCoding.encoder.encode(CategoryWrite(category))
        try writer.write { db in
            try category.save(db)
            try Self.enqueue(db, entity: .category, id: category.id, op: .put, body: body, now: now)
        }
    }

    public func deleteCategory(id: String, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE category SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
            try Self.enqueue(db, entity: .category, id: id, op: .delete, body: nil, now: now)
        }
    }

    public func saveSchedule(_ schedule: Schedule, now: Date = Date()) throws {
        var schedule = schedule
        schedule.updatedAt = now
        let body = try JSONCoding.encoder.encode(ScheduleWrite(schedule))
        try writer.write { db in
            try schedule.save(db)
            try Self.enqueue(db, entity: .schedule, id: schedule.id, op: .put, body: body, now: now)
        }
    }

    public func deleteSchedule(id: String, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE schedule SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
            try Self.enqueue(db, entity: .schedule, id: id, op: .delete, body: nil, now: now)
        }
    }

    /// Replaces any queued write for (entity, id) with a new one, so the queue holds one row per entity id.
    static func enqueue(_ db: Database, entity: PendingWrite.Entity, id: String, op: PendingWrite.Op, body: Data?, now: Date) throws {
        try db.execute(
            sql: "DELETE FROM pendingWrite WHERE entity = ? AND entityId = ?",
            arguments: [entity.rawValue, id])
        var write = PendingWrite(entity: entity, entityId: id, op: op, body: body, createdAt: now)
        try write.insert(db)
    }
}

// MARK: - Applying server data

extension AppDatabase {
    /// Merges a `GET /api/sync` response: upserts changed rows, drops tombstoned rows, replaces
    /// the placement, account and calendar tables, and stores the cursor. Tasks, categories and
    /// schedules with a queued local write are left alone; the local version is newer and will be pushed.
    public func apply(_ response: SyncResponse) throws {
        try writer.write { db in
            let pending = try Self.pendingEntityIds(db)

            for schedule in response.schedules where !pending.contains(.init(entity: .schedule, id: schedule.id)) {
                if schedule.deletedAt != nil {
                    try Schedule.deleteOne(db, id: schedule.id)
                } else {
                    try schedule.save(db)
                }
            }
            for category in response.categories where !pending.contains(.init(entity: .category, id: category.id)) {
                if category.deletedAt != nil {
                    try Category.deleteOne(db, id: category.id)
                } else {
                    try category.save(db)
                }
            }
            for task in response.tasks where !pending.contains(.init(entity: .task, id: task.id)) {
                if task.deletedAt != nil {
                    try TaskItem.deleteOne(db, id: task.id)
                } else {
                    try task.save(db)
                }
            }
            for event in response.events {
                if event.deletedAt != nil {
                    try CalendarEvent.deleteOne(db, id: event.id)
                } else {
                    try event.save(db)
                }
            }

            try Self.replacePlacements(db, with: response.placements)

            _ = try GoogleAccount.deleteAll(db)
            for account in response.accounts {
                try account.insert(db)
            }
            _ = try CalendarInfo.deleteAll(db)
            for calendar in response.calendars {
                try calendar.insert(db)
            }

            try db.execute(
                sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES ('cursor', ?)",
                arguments: [response.cursor])
        }
    }

    /// Replaces the placement table with the result of a scheduler run.
    public func apply(_ result: SchedulingResult, computedAt: Date) throws {
        try writer.write { db in
            try Self.replacePlacements(db, with: result.placementRows(computedAt: computedAt))
        }
    }

    static func replacePlacements(_ db: Database, with placements: [Placement]) throws {
        _ = try Placement.deleteAll(db)
        for placement in placements {
            try placement.insert(db)
        }
    }

    struct PendingEntityId: Hashable {
        var entity: PendingWrite.Entity
        var id: String
    }

    static func pendingEntityIds(_ db: Database) throws -> Set<PendingEntityId> {
        let rows = try Row.fetchAll(db, sql: "SELECT entity, entityId FROM pendingWrite")
        return Set(rows.compactMap { row in
            PendingWrite.Entity(rawValue: row["entity"]).map { PendingEntityId(entity: $0, id: row["entityId"]) }
        })
    }
}

// MARK: - Pending queue

extension AppDatabase {
    /// Queued local writes, oldest first.
    public func pendingWrites() throws -> [PendingWrite] {
        try writer.read { db in try PendingWrite.order(Column("seq")).fetchAll(db) }
    }

    public func removePendingWrite(seq: Int64) throws {
        try writer.write { db in
            _ = try PendingWrite.deleteOne(db, key: seq)
        }
    }

    /// Records that the server accepted `write`: removes it from the queue, applies the scheduler
    /// result, and stores the server's copy of the row unless a newer local write for the same
    /// entity has been queued since.
    func completePendingWrite<Record: PersistableRecord>(
        _ write: PendingWrite, record: Record?, scheduling: SchedulingResult, computedAt: Date
    ) throws {
        try writer.write { db in
            if let seq = write.seq {
                _ = try PendingWrite.deleteOne(db, key: seq)
            }
            let superseded = try Self.pendingEntityIds(db).contains(.init(entity: write.entity, id: write.entityId))
            if let record, !superseded {
                try record.save(db)
            }
            try Self.replacePlacements(db, with: scheduling.placementRows(computedAt: computedAt))
        }
    }
}
