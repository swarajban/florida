import Foundation
import GRDB

// MARK: - Reads

extension AppDatabase {
    /// Live routine blocks in the order a week reads: by first weekday (Monday first), then start time.
    public func routineBlocks() throws -> [RoutineBlock] {
        try writer.read { db in try Self.routineBlocks(db) }
    }

    static func routineBlocks(_ db: Database) throws -> [RoutineBlock] {
        // `days` is JSON text, so the order is computed here; the table holds a handful of rows.
        func firstDay(_ block: RoutineBlock) -> Int {
            block.days.map { ($0 + 6) % 7 }.min() ?? 7
        }
        return try RoutineBlock.filter(Column("deletedAt") == nil).fetchAll(db).sorted {
            (firstDay($0), $0.start, $0.id) < (firstDay($1), $1.start, $1.id)
        }
    }

    /// The server's settings row; nil until the first sync with a seeded server.
    public func userSettings() throws -> UserSettings? {
        try writer.read { db in try UserSettings.fetchOne(db) }
    }

    /// Live schedules, by name.
    public func schedules() throws -> [Schedule] {
        try writer.read { db in
            try Schedule.filter(Column("deletedAt") == nil).order(Column("name")).fetchAll(db)
        }
    }

    /// Live categories in the order they are listed: Inbox, work, personal, by name within each
    /// (`TaskCategory.isListedBefore`).
    public func categories() throws -> [TaskCategory] {
        try writer.read { db in
            try Self.categories(db)
        }
    }

    static func categories(_ db: Database) throws -> [TaskCategory] {
        try TaskCategory.filter(Column("deletedAt") == nil).fetchAll(db).inListOrder()
    }

    /// Live projects, by `sortOrder` then name.
    public func projects() throws -> [Project] {
        try writer.read { db in try Self.projects(db) }
    }

    static func projects(_ db: Database) throws -> [Project] {
        try Project.filter(Column("deletedAt") == nil).order(Column("sortOrder"), Column("name"), Column("id")).fetchAll(db)
    }

    public func project(id: String) throws -> Project? {
        try writer.read { db in try Project.fetchOne(db, id: id) }
    }

    /// Live day overrides, by date.
    public func dayOverrides() throws -> [DayOverride] {
        try writer.read { db in try Self.dayOverrides(db) }
    }

    static func dayOverrides(_ db: Database) throws -> [DayOverride] {
        try DayOverride.filter(Column("deletedAt") == nil).order(Column("date")).fetchAll(db)
    }

    /// Time held for projects, by start. The table only holds what the server keeps: the
    /// scheduler's horizon and the two weeks before it.
    public func projectPlacements() throws -> [ProjectPlacement] {
        try writer.read { db in try Self.projectPlacements(db) }
    }

    static func projectPlacements(_ db: Database) throws -> [ProjectPlacement] {
        try ProjectPlacement.order(Column("startAt"), Column("id")).fetchAll(db)
    }

    /// Where the commitments (the gym) land, by start, from the Sunday of the current week on.
    public func routineOccurrences() throws -> [RoutineOccurrence] {
        try writer.read { db in try Self.routineOccurrences(db) }
    }

    static func routineOccurrences(_ db: Database) throws -> [RoutineOccurrence] {
        try RoutineOccurrence.order(Column("startAt"), Column("id")).fetchAll(db)
    }

    /// What the last scheduler run says about the plan as a whole; empty before the first sync.
    public func planSummary() throws -> PlanSummary {
        try writer.read { db in try PlanSummary.fetchOne(db) ?? PlanSummary() }
    }

    /// The stored daily brief and weekly review, newest first.
    public func briefs() throws -> [Brief] {
        try writer.read { db in try Self.briefs(db) }
    }

    static func briefs(_ db: Database) throws -> [Brief] {
        try Brief.order(Column("date").desc, Column("kind")).fetchAll(db)
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

    /// The event row, whether or not it is visible (a locally deleted one still has its tombstone).
    public func event(id: String) throws -> CalendarEvent? {
        try writer.read { db in try CalendarEvent.fetchOne(db, id: id) }
    }

    /// Tasks the last scheduler run could not fully place, by task id.
    public func unscheduled() throws -> [UnscheduledTask] {
        try writer.read { db in try UnscheduledTask.order(Column("taskId")).fetchAll(db) }
    }

    /// The scheduler's suggestions for optional routine blocks, by start. Never part of the plan:
    /// keep them out of anything that answers "what is scheduled".
    public func optionalPlacements() throws -> [OptionalPlacement] {
        try writer.read { db in try Self.optionalPlacements(db) }
    }

    static func optionalPlacements(_ db: Database) throws -> [OptionalPlacement] {
        try OptionalPlacement.order(Column("startAt"), Column("taskId")).fetchAll(db)
    }

    /// Placements overlapping `range`, by start.
    public func placements(in range: Range<Date>) throws -> [Placement] {
        try writer.read { db in try Self.placements(db, in: range) }
    }

    /// Visible events (live, not cancelled, not declined) from selected calendars that overlap
    /// `range`, by start. All-day events count when one of their dates is a day of `calendar`
    /// that overlaps `range`, so a Nov 10 all-day event is on Nov 10 in every time zone.
    public func events(in range: Range<Date>, calendar: Calendar = .autoupdatingCurrent) throws -> [CalendarEvent] {
        try writer.read { db in try Self.events(db, in: range, calendar: calendar) }
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

    /// Visible events, scheduled task blocks, commitments and project time for the calendar day
    /// containing `day`.
    public func agenda(for day: Date, calendar: Calendar) throws -> DayAgenda {
        let range = Self.dayRange(containing: day, calendar: calendar)
        return try writer.read { db in try Self.agenda(db, in: range, calendar: calendar) }
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
        // Where DST skips midnight (Havana, Beirut) the day starts at 01:00 and adding a day keeps
        // that wall-clock time; `startOfDay` again lands on the next day's first instant.
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start..<calendar.startOfDay(for: next)
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
            guard let task = tasksById[placement.taskId], task.isOpen else { return nil }
            return ScheduledBlock(placement: placement, task: task)
        }
    }

    /// `range` must be one day of `calendar`, as `dayRange(containing:calendar:)` returns it.
    static func agenda(_ db: Database, in range: Range<Date>, calendar: Calendar) throws -> DayAgenda {
        DayAgenda(
            day: range.lowerBound,
            events: try events(db, in: range, calendar: calendar),
            placements: try scheduledBlocks(db, in: range),
            planBlocks: try planBlocks(db, in: range),
            completedTasks: try TaskItem
                .filter(Column("deletedAt") == nil && Column("completedAt") >= range.lowerBound && Column("completedAt") < range.upperBound)
                .order(Column("completedAt"), Column("id"))
                .fetchAll(db),
            blockingAllDayEvents: try blockingAllDayEvents(db, in: range, calendar: calendar))
    }

    /// The commitments and project time overlapping `range`, by start. Reads all four tables
    /// every time, so an observation built on it tracks each of them from its first fetch.
    static func planBlocks(_ db: Database, in range: Range<Date>) throws -> [PlanBlock] {
        let overlapping = Column("startAt") < range.upperBound && Column("endAt") > range.lowerBound
        let blocks = try RoutineBlock.fetchAll(db)
        let projects = try Project.fetchAll(db)
        return PlanBlock.join(
            occurrences: try RoutineOccurrence.filter(overlapping).fetchAll(db),
            projectPlacements: try ProjectPlacement.filter(overlapping).fetchAll(db),
            blocksById: Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            projectsById: Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Timed events are compared with `range` as instants; all-day events, stored as UTC
    /// midnights, with the stored range of the local days `range` touches.
    static func events(_ db: Database, in range: Range<Date>, calendar: Calendar) throws -> [CalendarEvent] {
        let allDay = AllDayDate.storedRange(overlapping: range, calendar: calendar)
        return try CalendarEvent.fetchAll(db, sql: """
            SELECT event.* FROM event
            JOIN calendar ON calendar.id = event.calendarId
            WHERE calendar.selected
              AND event.deletedAt IS NULL
              AND event.status <> 'cancelled'
              AND (event.responseStatus IS NULL OR event.responseStatus <> 'declined')
              AND event.startAt IS NOT NULL AND event.endAt IS NOT NULL
              AND ((event.allDay = 0 AND event.startAt < ? AND event.endAt > ?)
                OR (event.allDay = 1 AND event.startAt < ? AND event.endAt > ?))
            ORDER BY event.startAt
            """, arguments: [range.upperBound, range.lowerBound, allDay.upperBound, allDay.lowerBound])
    }

    static func cursor(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = 'cursor'")
    }
}

// MARK: - Local writes

extension AppDatabase {
    /// A local write refused before it reached the store or the queue.
    public enum WriteError: Error, Hashable, Sendable, LocalizedError {
        /// `saveEvent` of a row without `startAt` or `endAt`; the server requires both.
        case eventWithoutTimes(id: String)
        case eventNotAllDay(id: String)
        case taskNoLongerOpen
        case eventNoLongerExists
        case projectNoLongerExists
        case taskAlreadyRestored
        case taskNoLongerExists

        public var errorDescription: String? {
            switch self {
            case .eventWithoutTimes(let id): "Event \(id) has missing or invalid start and end times."
            case .eventNotAllDay(let id): "Event \(id) is not an all-day event."
            case .taskNoLongerOpen: "This task was deleted or completed elsewhere. Your changes were not saved."
            case .eventNoLongerExists: "This event was deleted elsewhere. Your changes were not saved."
            case .projectNoLongerExists: "This project was deleted elsewhere. Your changes were not saved."
            case .taskAlreadyRestored: "This task has already been restored or changed elsewhere."
            case .taskNoLongerExists: "This task was deleted elsewhere. Your changes were not saved."
            }
        }
    }

    /// Saves immediately and queues only changed user fields for an existing task. Creation and
    /// restoration use PUT; later edits merge into that PUT until it has been accepted.
    /// A change of `pinnedStart` also moves the task's block at once (see `placePin`).
    public func saveTask(_ task: TaskItem, now: Date = Date()) throws {
        try writer.write { db in
            try Self.saveTask(task, in: db, now: now)
        }
    }

    static func saveTask(_ task: TaskItem, in db: Database, now: Date) throws {
        let previous = try TaskItem.fetchOne(db, id: task.id)
        let pending = try PendingWrite.filter(Column("entity") == "task" && Column("entityId") == task.id).fetchOne(db)
        var local = task
        if previous?.deletedAt != nil || pending?.op == .delete || (previous == nil && task.recurrenceRevision != nil) {
            // Undo restores only this task. Sending the cached rule would instead look like a
            // stale attempt to restart the series after the delete rotated its revision.
            local.recurrence = nil
        }
        let fullBody = try JSONCoding.encoder.encode(TaskWrite(local))
        let full = try taskWriteObject(fullBody)
        let op: PendingWrite.Op
        let body: Data
        let needsCreation = try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: ["task-needs-put:\(task.id)"]) != nil
        if let previous, previous.deletedAt == nil, pending?.op != .delete, !needsCreation {
            var changes = taskChanges(from: previous, to: local, full: full)
            guard !changes.isEmpty else { return }
            // Completion/progress never edits the template and needs no recurrence precondition.
            if changes.keys.contains(where: { $0 != "completedAt" && $0 != "completedMinutes" }) {
                changes["expectedRecurrenceRevision"] = full["expectedRecurrenceRevision"]
            }
            var merged: [String: Any] = [:]
            if let pendingBody = pending?.body {
                merged = try taskWriteObject(pendingBody)
            }
            // Retain the original edit's baseline, including an explicit null. Replacing it with
            // a later edit's revision could silently turn a stale rule/template edit into a valid one.
            if let baseline = merged["expectedRecurrenceRevision"] {
                changes["expectedRecurrenceRevision"] = baseline
            }
            merged.merge(changes) { _, new in new }
            op = pending?.op == .put ? .put : .patch
            body = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        } else {
            op = .put
            body = fullBody
        }
        local.updatedAt = now
        if let previous {
            // Editors and undo own user fields, never server metadata.
            local.recurrenceSeriesId = previous.recurrenceSeriesId
            local.recurrenceDate = previous.recurrenceDate
            local.recurrenceRevision = previous.recurrenceRevision
        }
        if previous?.categoryId != local.categoryId {
            try forgetCategoryReassignment(db, entity: .task, id: local.id)
        }
        try local.save(db)
        try enqueue(db, entity: .task, id: task.id, op: op, body: body, now: now)
        if previous == nil || !taskSchedulingFields.isDisjoint(with: taskChanges(from: previous ?? local, to: local, full: full).keys) {
            try UnscheduledTask.filter(Column("taskId") == local.id).deleteAll(db)
            try OptionalPlacement.filter(Column("taskId") == local.id).deleteAll(db)
        }
        if local.pinnedStart != previous?.pinnedStart || (local.pinnedStart != nil && local.remainingMinutes != previous?.remainingMinutes) || !local.isOpen {
            try placePin(of: local, in: db, now: now)
        }
        if let start = local.startAt {
            try Placement.filter(Column("taskId") == local.id && Column("startAt") < start && Column("pinned") == false).deleteAll(db)
        }
        if let id = local.projectId, let project = try Project.fetchOne(db, id: id), project.status != .active || project.deletedAt != nil {
            try removeProjectTaskPlan(db, projectId: id)
        }
    }

    private static let taskSchedulingFields: Set<String> = ["categoryId", "durationMinutes", "minChunkMinutes", "priority", "deadlineType", "dueAt", "startAt", "scheduleId", "context", "projectId", "attention", "pinnedStart", "completedMinutes", "completedAt", "recurrence", "someday"]

    /// A pinned task sits at exactly its pinned start for its remaining minutes, so its block does
    /// not have to wait for the server: pinning shows it there at once, and unpinning takes it off
    /// the plan until the scheduler has placed it again. The next scheduler output replaces the
    /// block like every other row; other tasks keep their blocks until then.
    private static func placePin(of task: TaskItem, in db: Database, now: Date) throws {
        try Placement.filter(Column("taskId") == task.id).deleteAll(db)
        guard let start = task.pinnedStart, task.isOpen, task.remainingMinutes > 0 else { return }
        if let id = task.projectId, let project = try Project.fetchOne(db, id: id), project.status != .active || project.deletedAt != nil { return }
        try UnscheduledTask.filter(Column("taskId") == task.id).deleteAll(db)
        try Placement(
            id: UUID().uuidString.lowercased(), taskId: task.id, startAt: start,
            endAt: start.addingTimeInterval(TimeInterval(task.remainingMinutes) * 60), pinned: true, computedAt: now
        ).insert(db)
    }

    static func taskWriteObject(_ data: Data) throws -> [String: Any] {
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.typeMismatch([String: Any].self, .init(codingPath: [], debugDescription: "Task write must be a JSON object."))
        }
        return fields
    }

    /// Omitted means untouched; NSNull means intentionally cleared. Comparing dates through GRDB
    /// uses SQLite's millisecond precision, so saving an unrounded editor snapshot cannot turn
    /// completion into a spurious template/timing edit.
    private static func taskChanges(from before: TaskItem, to after: TaskItem, full: [String: Any]) -> [String: Any] {
        var changes: [String: Any] = [:]
        func track<Value: Equatable>(_ key: String, _ path: KeyPath<TaskItem, Value>) {
            if before[keyPath: path] != after[keyPath: path] {
                changes[key] = full[key] ?? NSNull()
            }
        }
        func trackDate(_ key: String, _ path: KeyPath<TaskItem, Date?>) {
            if before[keyPath: path]?.databaseValue != after[keyPath: path]?.databaseValue {
                changes[key] = full[key] ?? NSNull()
            }
        }
        track("categoryId", \.categoryId)
        track("title", \.title)
        track("notes", \.notes)
        track("source", \.source)
        track("durationMinutes", \.durationMinutes)
        track("minChunkMinutes", \.minChunkMinutes)
        track("priority", \.priority)
        track("deadlineType", \.deadlineType)
        trackDate("dueAt", \.dueAt)
        trackDate("startAt", \.startAt)
        track("scheduleId", \.scheduleId)
        track("context", \.context)
        track("projectId", \.projectId)
        track("attention", \.attention)
        trackDate("pinnedStart", \.pinnedStart)
        track("completedMinutes", \.completedMinutes)
        trackDate("completedAt", \.completedAt)
        track("recurrence", \.recurrence)
        return changes
    }

    /// Marks the task deleted locally and queues a `delete`, replacing any queued `put`.
    @discardableResult
    public func deleteTask(id: String, now: Date = Date()) throws -> TaskItem? {
        try writer.write { db in
            let task = try TaskItem.fetchOne(db, id: id)
            if let task, let series = task.recurrenceSeriesId, let date = task.recurrenceDate {
                try db.execute(sql: """
                    UPDATE task SET deletedAt = ?, updatedAt = ?
                    WHERE recurrenceSeriesId = ? AND recurrenceDate > ? AND completedAt IS NULL AND deletedAt IS NULL
                    """, arguments: [now, now, series, date])
                try db.execute(sql: """
                    UPDATE task SET recurrence = NULL, recurrenceSeriesId = NULL, recurrenceDate = NULL, updatedAt = ?
                    WHERE recurrenceSeriesId = ? AND id != ? AND completedAt IS NULL AND deletedAt IS NULL
                    """, arguments: [now, series, id])
            }
            try db.execute(sql: "UPDATE task SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
            try Self.enqueue(db, entity: .task, id: id, op: .delete, body: nil, now: now)
            return task
        }
    }

    /// Marks the task complete at `at` (its remaining minutes count as done).
    @discardableResult
    public func completeTask(id: String, at completedAt: Date = Date()) throws -> TaskMutation? {
        try writer.write { db in
            guard var task = try TaskItem.fetchOne(db, id: id), task.isOpen else { return nil }
            let before = task
            task.completedAt = completedAt
            task.completedMinutes = task.durationMinutes
            try Self.saveTask(task, in: db, now: completedAt)
            guard let after = try TaskItem.fetchOne(db, id: id) else { throw WriteError.taskNoLongerExists }
            return TaskMutation(before: before, after: after)
        }
    }

    public func reopenTask(id: String, now: Date = Date()) throws {
        try writer.write { db in
            guard var task = try TaskItem.fetchOne(db, id: id) else { return }
            task.completedAt = nil
            task.completedMinutes = 0
            try Self.saveTask(task, in: db, now: now)
        }
    }

    /// Upserts the event with `updatedAt = now` and queues a `put` for the server, replacing any
    /// earlier queued write for the same event. A new event has `googleId == ""` until the
    /// server's copy replaces the row; it shows up in `events(in:)` as soon as its calendar is selected.
    /// Throws `WriteError.eventWithoutTimes` for a row missing `startAt` or `endAt`, which the
    /// server would refuse; nothing is stored or queued.
    public func saveEvent(_ event: CalendarEvent, recurrence: EventRecurrence? = nil, now: Date = Date()) throws {
        try writer.write { db in
            try Self.saveEvent(event, recurrence: recurrence, in: db, now: now)
        }
    }

    static func saveEvent(_ event: CalendarEvent, recurrence: EventRecurrence?, in db: Database, now: Date) throws {
        var event = event
        event.updatedAt = now
        guard let initial = EventWrite(event) else { throw WriteError.eventWithoutTimes(id: event.id) }
        var write = initial
        if let stored = try CalendarEvent.fetchOne(db, key: event.id) {
            event.blocksDay = stored.blocksDay
            write.blocksDay = stored.blocksDay
            event.autoBlocksDay = stored.autoBlocksDay
            event.blockingReason = stored.blockingReason
        }
        write.recurrence = recurrence
        if let pending = try PendingWrite.filter(Column("entity") == "event" && Column("entityId") == event.id).fetchOne(db),
           pending.op == .put, let body = pending.body {
            let queued = try JSONCoding.decoder.decode(EventWrite.self, from: body)
            // An offline rename/reschedule must not erase the queued series creation.
            if write.recurrence == nil, event.googleId.isEmpty {
                write.recurrence = queued.recurrence
            }
            // Nor may an RSVP or a rename erase a queued move of the whole series: the other
            // instances have moved here already, and only this write tells the server.
            if queued.scope == .series, queued.startAt == write.startAt, queued.endAt == write.endAt {
                write.scope = .series
            } else if queued.scope == .series {
                try Self.restoreSeriesMove(db, id: event.id)
            }
        }
        let body = try JSONCoding.encoder.encode(write)
        try event.save(db)
        try Self.enqueue(db, entity: .event, id: event.id, op: .put, body: body, now: now)
    }

    /// Moves a repeating event as a whole. The instance `instanceId` goes to `start`…`end`; every
    /// other live timed row of its series on the same calendar shifts by as much and takes the
    /// same length, so each keeps its day. Queues one `put`, for the instance, with
    /// `scope: series`: the server moves the series on Google from it, and its rows replace these
    /// on the next sync. An event that does not repeat moves alone.
    /// Throws `WriteError.eventWithoutTimes` when there is no such row or it has no times.
    @discardableResult
    public func moveEventSeries(instanceId: String, start: Date, end: Date, now: Date = Date()) throws -> EventMutation {
        try writer.write { db in
            try Self.moveEventSeries(instanceId: instanceId, start: start, end: end, in: db, now: now)
        }
    }

    static func moveEventSeries(instanceId: String, start: Date, end: Date, in db: Database, now: Date) throws -> EventMutation {
        guard var instance = try CalendarEvent.fetchOne(db, id: instanceId), let oldStart = instance.startAt,
              let oldEnd = instance.endAt, oldEnd > oldStart, end > start,
              instance.deletedAt == nil, instance.status != "cancelled"
        else { throw WriteError.eventWithoutTimes(id: instanceId) }
        let shift = start.timeIntervalSince(oldStart)
        let length = end.timeIntervalSince(start)
        var snapshots = try Self.seriesMoveTimes(db, id: instanceId)
        if let series = instance.recurringEventId {
            let others = try CalendarEvent
                .filter(Column("calendarId") == instance.calendarId && Column("recurringEventId") == series)
                .filter(Column("id") != instanceId && Column("deletedAt") == nil && Column("allDay") == false)
                .fetchAll(db)
            for var other in others {
                guard let otherStart = other.startAt else { continue }
                let moved = otherStart.addingTimeInterval(shift)
                let previous = snapshots.first { $0.id == other.id }
                snapshots.removeAll { $0.id == other.id }
                snapshots.append(SeriesMoveTimes(id: other.id, start: previous?.start ?? other.startAt,
                    end: previous?.end ?? other.endAt, movedStart: moved, movedEnd: moved.addingTimeInterval(length)))
                other.startAt = moved
                other.endAt = moved.addingTimeInterval(length)
                other.updatedAt = now
                try other.save(db)
            }
        }
        instance.startAt = start
        instance.endAt = end
        instance.updatedAt = now
        guard var write = EventWrite(instance) else { throw WriteError.eventWithoutTimes(id: instanceId) }
        write.scope = .series
        try instance.save(db)
        try Self.storeSeriesMoveTimes(db, id: instanceId, times: snapshots)
        try Self.enqueue(db, entity: .event, id: instanceId, op: .put, body: try JSONCoding.encoder.encode(write), now: now)
        return EventMutation(from: DateInterval(start: oldStart, end: oldEnd), to: DateInterval(start: start, end: end))
    }

    /// Marks the event deleted locally, so every query and observation hides it at once, and
    /// queues a `delete`, replacing any queued `put`.
    public func deleteEvent(id: String, now: Date = Date()) throws {
        try writer.write { db in
            try Self.restoreSeriesMove(db, id: id)
            try db.execute(sql: "UPDATE event SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
            try Self.enqueue(db, entity: .event, id: id, op: .delete, body: nil, now: now)
        }
    }

    public func saveCategory(_ category: TaskCategory, now: Date = Date()) throws {
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
            try Self.keepPendingCategoryReassignments(db)
        }
    }

    /// Saves the project and queues a `put`. Its tasks keep their blocks until the server has
    /// rescheduled; the push's answer brings the new plan.
    public func saveProject(_ project: Project, now: Date = Date()) throws {
        try writer.write { db in
            try Self.saveProject(project, in: db, now: now)
        }
    }

    static func saveProject(_ project: Project, in db: Database, now: Date) throws {
        var project = project
        project.updatedAt = now
        let body = try JSONCoding.encoder.encode(ProjectWrite(project))
        let previous = try Project.fetchOne(db, id: project.id)
        if previous == nil || previous?.categoryId != project.categoryId {
            try Self.forgetCategoryReassignment(db, entity: .project, id: project.id)
        }
        try project.save(db)
        try Self.enqueue(db, entity: .project, id: project.id, op: .put, body: body, now: now)
        if project.status != .active {
            try Self.removeProjectTaskPlan(db, projectId: project.id)
        }
    }

    private static func removeProjectTaskPlan(_ db: Database, projectId: String) throws {
        try db.execute(sql: "DELETE FROM placement WHERE taskId IN (SELECT id FROM task WHERE projectId = ?)", arguments: [projectId])
        try db.execute(sql: "DELETE FROM optionalPlacement WHERE taskId IN (SELECT id FROM task WHERE projectId = ?)", arguments: [projectId])
        try db.execute(sql: "DELETE FROM unscheduled WHERE taskId IN (SELECT id FROM task WHERE projectId = ?)", arguments: [projectId])
    }

    /// Marks the project deleted and queues a `delete`. Its tasks stay, unfiled from it, as the
    /// server leaves them; no task write is queued, because deleting the project does that there.
    /// A task write already queued stops naming the project: the server refuses a project it does
    /// not know ("unknown projectId"), which would drop that task's other edits with it when the
    /// project itself was never pushed.
    public func deleteProject(id: String, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE project SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
            try db.execute(sql: "UPDATE task SET projectId = NULL WHERE projectId = ?", arguments: [id])
            for var write in try PendingWrite.filter(Column("entity") == PendingWrite.Entity.task.rawValue).fetchAll(db)
            where write.namedProjectId == id {
                guard let body = write.body else { continue }
                var fields = try Self.taskWriteObject(body)
                fields["projectId"] = NSNull()
                write.body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
                try write.update(db)
            }
            try Self.enqueue(db, entity: .project, id: id, op: .delete, body: nil, now: now)
        }
    }

    /// Makes `date` ("YYYY-MM-DD" in the routine's zone) a home, office or off day and queues a `put`.
    public func setDay(_ date: String, kind: DayKind, note: String? = nil, now: Date = Date()) throws {
        try writer.write { db in
            let createdAt = try DayOverride.fetchOne(db, id: date)?.createdAt ?? now
            let override = DayOverride(date: date, kind: kind, note: note, createdAt: createdAt, updatedAt: now)
            try override.save(db)
            let body = try JSONCoding.encoder.encode(DayOverrideWrite(override))
            try Self.enqueue(db, entity: .dayOverride, id: date, op: .put, body: body, now: now)
        }
    }

    /// Puts `date` back on its weekday's routine and queues a `delete`. Does nothing for a date
    /// without an override.
    public func clearDay(_ date: String, now: Date = Date()) throws {
        try writer.write { db in
            guard let override = try DayOverride.fetchOne(db, id: date), override.deletedAt == nil else { return }
            try db.execute(sql: "UPDATE dayOverride SET deletedAt = ?, updatedAt = ? WHERE date = ?", arguments: [now, now, date])
            try Self.enqueue(db, entity: .dayOverride, id: date, op: .delete, body: nil, now: now)
        }
    }

    /// Stores a brief the server just wrote, replacing the stored one of its kind.
    public func storeBrief(_ brief: Brief) throws {
        try writer.write { db in
            _ = try Brief.filter(Column("kind") == brief.kind.rawValue).deleteAll(db)
            try brief.save(db)
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
        if op != .delete {
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: ["creation-delete:\(entity.rawValue):\(id)"])
        }
        if op == .delete, try PendingWrite.filter(Column("entity") == entity.rawValue && Column("entityId") == id && Column("op") == "put").fetchCount(db) > 0 {
            try db.execute(sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES (?, '1')", arguments: ["creation-delete:\(entity.rawValue):\(id)"])
        }
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
    /// the settings, scheduler output (placements, suggestions, unscheduled, project time, commitments, plan summary),
    /// brief, account and calendar tables, and stores the cursor. Tasks, categories, schedules, events, projects and
    /// day overrides with a queued local write are left alone; the local version is newer and will be pushed.
    public func apply(_ response: SyncResponse) throws {
        try writer.write { db in
            let pending = try Self.pendingEntityIds(db)

            // The routine and settings are server-owned, so no local write can be newer.
            for block in response.routineBlocks {
                if block.deletedAt != nil {
                    try RoutineBlock.deleteOne(db, id: block.id)
                } else {
                    try block.save(db)
                }
            }
            _ = try UserSettings.deleteAll(db)
            try response.settings?.insert(db)

            for schedule in response.schedules where !pending.contains(.init(entity: .schedule, id: schedule.id)) {
                if schedule.deletedAt != nil {
                    try Schedule.deleteOne(db, id: schedule.id)
                } else {
                    try schedule.save(db)
                }
            }
            for category in response.categories where !pending.contains(.init(entity: .category, id: category.id)) {
                if category.deletedAt != nil {
                    try TaskCategory.deleteOne(db, id: category.id)
                } else {
                    try category.save(db)
                }
            }
            for project in response.projects where !pending.contains(.init(entity: .project, id: project.id)) {
                try Self.forgetCategoryReassignment(db, entity: .project, id: project.id)
                if project.deletedAt != nil {
                    try Project.deleteOne(db, id: project.id)
                } else {
                    try project.save(db)
                }
            }
            for override in response.dayOverrides where !pending.contains(.init(entity: .dayOverride, id: override.date)) {
                if override.deletedAt != nil {
                    try DayOverride.deleteOne(db, id: override.date)
                } else {
                    try override.save(db)
                }
            }
            for task in response.tasks where !pending.contains(.init(entity: .task, id: task.id)) {
                try Self.forgetCategoryReassignment(db, entity: .task, id: task.id)
                try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: ["task-needs-put:\(task.id)"])
                if task.deletedAt != nil {
                    try TaskItem.deleteOne(db, id: task.id)
                } else {
                    try task.save(db)
                }
            }
            for event in response.events where !pending.contains(.init(entity: .event, id: event.id)) {
                if event.deletedAt != nil {
                    try CalendarEvent.deleteOne(db, id: event.id)
                } else {
                    try event.save(db)
                }
            }
            try Self.keepPendingCategoryReassignments(db)
            for category in response.categories where !pending.contains(.init(entity: .category, id: category.id)) {
                if category.deletedAt == nil {
                    try Self.restoreCategoryReassignment(db, id: category.id)
                } else {
                    try Self.finishCategoryDeletion(db, id: category.id)
                }
            }

            try Self.replacePlacements(db, with: response.placements)
            try Self.replaceOptionalPlacements(db, with: response.optionalPlacements)
            try Self.replaceUnscheduled(db, with: response.unscheduled)
            try Self.replaceAll(db, with: response.projectPlacements)
            try Self.replaceAll(db, with: response.routineOccurrences)
            try Self.replaceAll(db, with: [response.planSummary])
            try Self.replaceAll(db, with: response.briefs)
            try Self.keepQueuedPins(db, pending: pending)

            _ = try GoogleAccount.deleteAll(db)
            for account in response.accounts {
                try account.insert(db)
            }
            let queuedCalendars = try CalendarInfo.fetchAll(db).filter { pending.contains(.init(entity: .calendar, id: $0.id)) }
            let calendarWrites = try PendingWrite.filter(Column("entity") == "calendar").fetchAll(db)
            _ = try CalendarInfo.deleteAll(db)
            for var calendar in response.calendars {
                if let write = calendarWrites.first(where: { $0.entityId == calendar.id }), let body = write.body {
                    let fields = try JSONCoding.decoder.decode([String: Bool].self, from: body)
                    if let selected = fields["selected"] { calendar.selected = selected }
                    if let blocks = fields["blocksScheduling"] { calendar.blocksScheduling = blocks }
                }
                try calendar.insert(db)
            }
            for calendar in queuedCalendars where !response.calendars.contains(where: { $0.id == calendar.id }) {
                try calendar.insert(db)
            }

            try db.execute(
                sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES ('cursor', ?)",
                arguments: [response.cursor])
        }
    }

    /// Replaces the scheduler's output tables with the result of a scheduler run.
    public func apply(_ result: SchedulingResult, computedAt: Date) throws {
        try writer.write { db in
            try Self.replaceSchedulerOutput(db, with: result, computedAt: computedAt)
        }
    }

    /// A pull can answer before a queued task write is pushed, so its placements may predate a pin
    /// or unpin the user already sees. Where the local pin and the pulled blocks disagree, the pin
    /// wins (see `placePin`); the push's own scheduler result settles it for good.
    private static func keepQueuedPins(_ db: Database, pending: Set<PendingEntityId>) throws {
        for entry in pending where entry.entity == .task {
            guard let task = try TaskItem.fetchOne(db, id: entry.id) else { continue }
            if let write = try PendingWrite.filter(Column("entity") == "task" && Column("entityId") == task.id).fetchOne(db), let body = write.body,
               !taskSchedulingFields.isDisjoint(with: try taskWriteObject(body).keys) {
                try UnscheduledTask.filter(Column("taskId") == task.id).deleteAll(db)
                try OptionalPlacement.filter(Column("taskId") == task.id).deleteAll(db)
            }
            let blocks = try Placement.filter(Column("taskId") == task.id).fetchAll(db)
            let agrees = if let pin = task.pinnedStart {
                blocks.count == 1 && blocks[0].pinned && blocks[0].startAt == pin
                    && blocks[0].endAt == pin.addingTimeInterval(TimeInterval(task.remainingMinutes) * 60) && task.isOpen
            } else {
                !blocks.contains(where: \.pinned)
            }
            if !agrees {
                try placePin(of: task, in: db, now: task.updatedAt)
            }
            if !task.isOpen {
                try Placement.filter(Column("taskId") == task.id).deleteAll(db)
                try OptionalPlacement.filter(Column("taskId") == task.id).deleteAll(db)
                try UnscheduledTask.filter(Column("taskId") == task.id).deleteAll(db)
            } else if let start = task.startAt {
                try Placement.filter(Column("taskId") == task.id && Column("startAt") < start && Column("pinned") == false).deleteAll(db)
            }
            if let id = task.projectId, let project = try Project.fetchOne(db, id: id), project.status != .active || project.deletedAt != nil {
                try removeProjectTaskPlan(db, projectId: id)
            }
        }
        for entry in pending where entry.entity == .project {
            if let project = try Project.fetchOne(db, id: entry.id), project.status != .active {
                try removeProjectTaskPlan(db, projectId: project.id)
            }
        }
    }

    static func replaceSchedulerOutput(_ db: Database, with result: SchedulingResult, computedAt: Date) throws {
        try replacePlacements(db, with: result.placementRows(computedAt: computedAt))
        try replaceOptionalPlacements(db, with: result.optionalPlacementRows(computedAt: computedAt))
        try replaceUnscheduled(db, with: result.unscheduledRows(computedAt: computedAt))
        // Ended project time is the record of time spent: the server keeps it and a run does not
        // return it, so only the blocks still ahead are this run's to replace.
        _ = try ProjectPlacement.filter(Column("endAt") > computedAt).deleteAll(db)
        for row in result.projectPlacementRows(computedAt: computedAt) {
            try row.insert(db)
        }
        try replaceAll(db, with: result.routineOccurrenceRows(computedAt: computedAt))
        try replaceAll(db, with: [result.planSummary])
        try keepQueuedPins(db, pending: pendingEntityIds(db))
    }

    /// Replaces every row of a table the server owns outright.
    static func replaceAll<Record: PersistableRecord>(_ db: Database, with rows: [Record]) throws {
        _ = try Record.deleteAll(db)
        for row in rows {
            try row.insert(db)
        }
    }

    static func replaceOptionalPlacements(_ db: Database, with rows: [OptionalPlacement]) throws {
        _ = try OptionalPlacement.deleteAll(db)
        for row in rows {
            try row.insert(db)
        }
    }

    static func replacePlacements(_ db: Database, with placements: [Placement]) throws {
        _ = try Placement.deleteAll(db)
        for placement in placements {
            try placement.insert(db)
        }
    }

    static func replaceUnscheduled(_ db: Database, with rows: [UnscheduledTask]) throws {
        _ = try UnscheduledTask.deleteAll(db)
        for row in rows {
            // `save` so a repeated task id overwrites instead of failing the whole apply.
            try row.save(db)
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

    func pendingWrite(seq: Int64) throws -> PendingWrite? {
        try writer.read { db in try PendingWrite.fetchOne(db, key: seq) }
    }

    func hasPendingCategoryWrites() throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM pendingWrite WHERE entity = ?)", arguments: [PendingWrite.Entity.category.rawValue]) == true
        }
    }

    func deletedQueuedCreation(_ write: PendingWrite) throws -> Bool {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: ["creation-delete:\(write.entity.rawValue):\(write.entityId)"]) != nil
        }
    }

    public func removePendingWrite(seq: Int64) throws {
        try writer.write { db in
            if let write = try PendingWrite.fetchOne(db, key: seq) {
                if write.entity == .event { try Self.restoreSeriesMove(db, id: write.entityId) }
                if write.entity == .category, write.op == .delete {
                    try db.execute(sql: "DELETE FROM syncState WHERE key = 'cursor'")
                }
            }
            _ = try PendingWrite.deleteOne(db, key: seq)
        }
    }

    /// Retries the original refused request, not a new snapshot of the reconciled row. In
    /// particular a PATCH retains its omissions and original revision precondition, and a failed
    /// creation stays a PUT even though its local row still exists. Newer queued intent wins.
    /// The row stays reconciled until the server accepts the retry.
    public func requeue(_ write: PendingWrite, now: Date = Date()) throws {
        try writer.write { db in
            guard !(try Self.pendingEntityIds(db).contains(.init(entity: write.entity, id: write.entityId))) else { return }
            try Self.enqueue(db, entity: write.entity, id: write.entityId, op: write.op, body: write.body, now: now)
        }
    }

    /// What the server has for an entity, as `GET /api/<collection>/:id` reports it.
    enum ServerCopy {
        /// A live row, as `/api/sync` serializes it.
        case live(any PersistableRecord)
        /// The row exists on the server with `deletedAt` set.
        case tombstoned
        /// 404 with the server's `{error}` body: the server never had the row.
        case missing
        /// 404 without that body (an older server lacking the route): nothing is known.
        case unavailable
    }

    /// Records that `write` left the queue without being applied (rejected or discarded): removes it
    /// and, unless a newer local write for the same entity has been queued since, resets the local
    /// row to the server's copy. A live row is saved; a tombstone removes the row. A row the server
    /// never had is removed only when the write was itself a delete (the local row is already a
    /// tombstone); a rejected `put` of such a row stays, so what the user typed is not lost. An
    /// unavailable copy leaves the row as it is.
    func resolveDroppedWrite(_ write: PendingWrite, serverCopy: ServerCopy) throws {
        try writer.write { db in
            if let seq = write.seq {
                _ = try PendingWrite.deleteOne(db, key: seq)
            }
            if write.entity == .category {
                try Self.settleCategoryAction(db, id: write.entityId, serverCopy: serverCopy)
            }
            guard !(try Self.pendingEntityIds(db).contains(.init(entity: write.entity, id: write.entityId))) else { return }
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: ["creation-delete:\(write.entity.rawValue):\(write.entityId)"])
            if write.entity == .event {
                try Self.restoreSeriesMove(db, id: write.entityId)
            }
            switch serverCopy {
            case .live(let row):
                if write.entity == .task || write.entity == .project {
                    try Self.forgetCategoryReassignment(db, entity: write.entity, id: write.entityId)
                }
                try row.save(db)
            case .tombstoned:
                try Self.deleteRow(db, entity: write.entity, id: write.entityId)
            case .missing where write.op == .delete:
                try Self.deleteRow(db, entity: write.entity, id: write.entityId)
            case .missing where write.entity == .task && write.op == .put:
                try db.execute(sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES (?, '1')", arguments: ["task-needs-put:\(write.entityId)"])
            case .missing, .unavailable:
                break
            }
            try Self.keepPendingCategoryReassignments(db)
            if write.entity == .task {
                if case .live = serverCopy, let task = try TaskItem.fetchOne(db, id: write.entityId) {
                    let hasPin = try Placement.filter(Column("taskId") == task.id && Column("pinned") == true).fetchCount(db) > 0
                    if hasPin || task.pinnedStart != nil {
                        try Self.placePin(of: task, in: db, now: task.updatedAt)
                    }
                } else if case .unavailable = serverCopy {
                    try Placement.filter(Column("taskId") == write.entityId && Column("pinned") == true).deleteAll(db)
                } else {
                    try Placement.filter(Column("taskId") == write.entityId).deleteAll(db)
                }
            }
        }
    }

    private static func deleteRow(_ db: Database, entity: PendingWrite.Entity, id: String) throws {
        if entity == .task || entity == .project {
            try Self.forgetCategoryReassignment(db, entity: entity, id: id)
        }
        if entity == .task {
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: ["task-needs-put:\(id)"])
        }
        switch entity {
        case .task: _ = try TaskItem.deleteOne(db, id: id)
        case .category: _ = try TaskCategory.deleteOne(db, id: id)
        case .schedule: _ = try Schedule.deleteOne(db, id: id)
        case .event: _ = try CalendarEvent.deleteOne(db, id: id)
        case .project: _ = try Project.deleteOne(db, id: id)
        case .dayOverride: _ = try DayOverride.deleteOne(db, id: id)
        case .calendar: _ = try CalendarInfo.deleteOne(db, id: id)
        }
    }

    /// Records that the server accepted `write`: removes it from the queue, applies the scheduler
    /// result (placements and unscheduled tasks), and, unless a newer local write for the same
    /// entity has been queued since, stores the server's copy of the row (a `put`) or removes the
    /// local tombstone (a `delete`; the server's own tombstone would remove it on the next pull anyway).
    func completePendingWrite<Record: PersistableRecord>(
        _ write: PendingWrite, record: Record?, scheduling: SchedulingResult, computedAt: Date
    ) throws {
        try writer.write { db in
            if let seq = write.seq {
                _ = try PendingWrite.deleteOne(db, key: seq)
            }
            let superseded = try Self.pendingEntityIds(db).contains(.init(entity: write.entity, id: write.entityId))
            if write.entity == .category {
                if write.op == .delete {
                    try Self.settleCategoryAction(db, id: write.entityId, serverCopy: .tombstoned)
                } else if let category = record as? TaskCategory {
                    try Self.settleCategoryAction(db, id: write.entityId,
                        serverCopy: category.deletedAt == nil ? .live(category) : .tombstoned)
                }
            }
            if superseded, write.entity == .event, let accepted = record as? CalendarEvent {
                try Self.rebaseSeriesMove(db, acknowledged: write, accepted: accepted)
            }
            if write.entity == .task {
                try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: ["task-needs-put:\(write.entityId)"])
                if superseded, let accepted = record as? TaskItem {
                    try db.execute(sql: "UPDATE task SET recurrenceRevision = ?, recurrenceSeriesId = ?, recurrenceDate = ? WHERE id = ?", arguments: [accepted.recurrenceRevision, accepted.recurrenceSeriesId, accepted.recurrenceDate, write.entityId])
                    if var newer = try PendingWrite.filter(Column("entity") == "task" && Column("entityId") == write.entityId).fetchOne(db), newer.op != .delete, let body = newer.body {
                        var fields = try Self.taskWriteObject(body)
                        if fields["expectedRecurrenceRevision"] != nil {
                            fields["expectedRecurrenceRevision"] = accepted.recurrenceRevision.map { $0 as Any } ?? NSNull()
                        }
                        if accepted.recurrenceRevision != nil { newer.op = .patch }
                        newer.body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
                        try newer.update(db)
                    }
                }
            }
            if !superseded {
                try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: ["creation-delete:\(write.entity.rawValue):\(write.entityId)"])
                if write.entity == .event {
                    try Self.clearSeriesMove(db, id: write.entityId)
                }
                if let record {
                    if write.entity == .task || write.entity == .project {
                        try Self.forgetCategoryReassignment(db, entity: write.entity, id: write.entityId)
                    }
                    try record.save(db)
                } else if write.op == .delete {
                    try Self.deleteRow(db, entity: write.entity, id: write.entityId)
                }
            }
            try Self.keepPendingCategoryReassignments(db)
            try Self.replaceSchedulerOutput(db, with: scheduling, computedAt: computedAt)
        }
    }
}
