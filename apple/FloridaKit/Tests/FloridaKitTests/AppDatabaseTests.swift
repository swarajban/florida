import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct AppDatabaseTests {
    // MARK: 1. Migrations + JSON column

    @Test func migratesAndRoundTripsScheduleWindows() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        for expected in ["schedule", "project", "task", "placement", "event", "googleAccount", "calendar", "syncState", "pendingWrite"] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }

        let windows = [
            ScheduleWindow(days: [1, 2, 3, 4, 5], start: "09:00", end: "12:00"),
            ScheduleWindow(days: [6], start: "10:30", end: "14:00"),
        ]
        try db.saveSchedule(Fixtures.schedule(id: "work", windows: windows), now: Fixtures.t0)

        let stored = try db.schedules()
        #expect(stored.count == 1)
        #expect(stored.first?.windows == windows)
        #expect(stored.first?.timeZone == "America/Los_Angeles")
        #expect(stored.first?.updatedAt == Fixtures.t0)

        // The column really is JSON text, not a blob of something else.
        let raw = try db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT windows FROM schedule WHERE id = 'work'")
        }
        let decoded = try JSONDecoder().decode([ScheduleWindow].self, from: Data(try #require(raw).utf8))
        #expect(decoded == windows)
    }

    @Test func defaultURLIsInsideAppGroupPath() {
        let url = AppDatabase.defaultURL()
        #expect(url.lastPathComponent == "florida.sqlite")
        #expect(url.path.contains(Florida.appGroup) || url.path.contains("Florida"))
    }

    @Test func opensFileStoreCreatingParentDirectories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fk-test-\(UUID().uuidString)/nested")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let db = try AppDatabase(path: path)
        #expect(FileManager.default.fileExists(atPath: path))
        let journalMode = try db.writer.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(journalMode?.lowercased() == "wal")
        try db.saveProject(Fixtures.project(), now: Fixtures.t0)
        #expect(try db.projects().count == 1)
    }

    // MARK: 2. apply(SyncResponse)

    @Test func applySyncResponseInsertsReplacesAndTombstones() throws {
        let db = try AppDatabase.inMemory()
        let first = SyncResponse(
            cursor: "2026-11-08T10:00:00.000Z",
            schedules: [Fixtures.schedule()],
            projects: [Fixtures.project()],
            tasks: [Fixtures.task(id: "t1"), Fixtures.task(id: "t2")],
            events: [Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")],
            placements: [Fixtures.placement(id: "p1", taskId: "t1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z")],
            accounts: [Fixtures.account()],
            calendars: [Fixtures.calendar(id: "cal"), Fixtures.calendar(id: "old")])
        try db.apply(first)

        #expect(try db.schedules().map(\.id) == ["work"])
        #expect(try db.projects().map(\.id) == ["inbox"])
        #expect(try db.openTasks().map(\.id) == ["t1", "t2"])
        #expect(try db.events(in: Fixtures.allTime).map(\.id) == ["e1"])
        #expect(try db.placements(in: Fixtures.allTime).map(\.id) == ["p1"])
        #expect(try db.accounts().map(\.id) == ["acct"])
        #expect(try db.calendars().map(\.id) == ["cal", "old"])
        #expect(try db.cursor() == "2026-11-08T10:00:00.000Z")

        // A second diff: tombstone t2, a changed t1, replaced placements and calendars.
        var changedT1 = Fixtures.task(id: "t1", title: "renamed")
        changedT1.updatedAt = Fixtures.instant("2026-11-08T11:00:00Z")
        let second = SyncResponse(
            cursor: "2026-11-08T12:00:00.000Z",
            tasks: [changedT1, Fixtures.task(id: "t2", deletedAt: Fixtures.instant("2026-11-08T11:30:00Z"))],
            events: [Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z",
                                    deletedAt: Fixtures.instant("2026-11-08T11:30:00Z"))],
            placements: [Fixtures.placement(id: "p2", taskId: "t1", start: "2026-11-10T17:00:00Z", end: "2026-11-10T18:00:00Z")],
            accounts: [Fixtures.account()],
            calendars: [Fixtures.calendar(id: "cal")])
        try db.apply(second)

        let tasks = try db.openTasks()
        #expect(tasks.map(\.id) == ["t1"])
        #expect(tasks.first?.title == "renamed")
        #expect(try db.task(id: "t2") == nil, "tombstones are not kept locally")
        #expect(try db.events(in: Fixtures.allTime).isEmpty)
        #expect(try db.placements(in: Fixtures.allTime).map(\.id) == ["p2"])
        #expect(try db.calendars().map(\.id) == ["cal"])
        #expect(try db.cursor() == "2026-11-08T12:00:00.000Z")

        // Schedules and projects were absent from the second diff and must survive.
        #expect(try db.schedules().count == 1)
        #expect(try db.projects().count == 1)
    }

    @Test func applySyncResponseSkipsRowsWithPendingLocalWrites() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c1", projects: [Fixtures.project()], tasks: [Fixtures.task(id: "t1"), Fixtures.task(id: "t2")]))

        // Local edit to t1 not yet pushed; local delete of t2 not yet pushed.
        var local = try #require(try db.task(id: "t1"))
        local.title = "local edit"
        try db.saveTask(local, now: Fixtures.instant("2026-11-08T13:00:00Z"))
        try db.deleteTask(id: "t2", now: Fixtures.instant("2026-11-08T13:00:00Z"))

        // Server sends an older-looking version of t1 and a live t2 → both must be ignored.
        try db.apply(SyncResponse(
            cursor: "c2",
            tasks: [Fixtures.task(id: "t1", title: "server edit"), Fixtures.task(id: "t2", title: "still alive")]))

        #expect(try db.task(id: "t1")?.title == "local edit")
        #expect(try db.task(id: "t2")?.deletedAt != nil)
        #expect(try db.openTasks().map(\.id) == ["t1"])
        #expect(try db.cursor() == "c2")

        // A row with no pending write is still applied normally.
        try db.apply(SyncResponse(cursor: "c3", tasks: [Fixtures.task(id: "t3")]))
        #expect(try db.task(id: "t3") != nil)
    }

    @Test func applySchedulingResultReplacesPlacements() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", placements: [
            Fixtures.placement(id: "p1", taskId: "t1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z"),
        ]))
        let computedAt = Fixtures.instant("2026-11-08T15:00:00Z")
        try db.apply(SchedulingResult(placements: [
            Fixtures.piece(taskId: "t1", start: "2026-11-10T09:00:00Z", end: "2026-11-10T10:00:00Z"),
            Fixtures.piece(taskId: "t2", start: "2026-11-10T10:00:00Z", end: "2026-11-10T11:00:00Z"),
        ]), computedAt: computedAt)

        let placements = try db.placements(in: Fixtures.allTime)
        #expect(placements.map(\.taskId) == ["t1", "t2"])
        #expect(placements.allSatisfy { $0.computedAt == computedAt })
        #expect(!placements.map(\.id).contains("p1"))
    }

    // MARK: 3. Ordering and event visibility

    @Test func openTasksOrdering() throws {
        let db = try AppDatabase.inMemory()
        let due = Fixtures.instant("2026-11-12T00:00:00Z")
        let dueLater = Fixtures.instant("2026-11-20T00:00:00Z")
        try db.apply(SyncResponse(cursor: "c", tasks: [
            Fixtures.task(id: "low-nodue", priority: .low),
            Fixtures.task(id: "medium-later", priority: .medium, dueAt: dueLater),
            Fixtures.task(id: "medium-nodue", priority: .medium),
            Fixtures.task(id: "medium-soon", priority: .medium, dueAt: due),
            Fixtures.task(id: "asap-nodue", priority: .asap),
            Fixtures.task(id: "high-nodue-old", priority: .high, createdAt: Fixtures.instant("2026-11-01T00:00:00Z")),
            Fixtures.task(id: "high-nodue-new", priority: .high, createdAt: Fixtures.instant("2026-11-05T00:00:00Z")),
            Fixtures.task(id: "done", priority: .asap, completedAt: Fixtures.t0),
            Fixtures.task(id: "gone", priority: .asap, deletedAt: Fixtures.t0),
        ]))

        // Note: "gone" is a tombstone and is dropped by apply; "done" is stored but not open.
        #expect(try db.openTasks().map(\.id) == [
            "asap-nodue",
            "high-nodue-old", "high-nodue-new",
            "medium-soon", "medium-later", "medium-nodue",
            "low-nodue",
        ])
        #expect(try db.tasks(inProject: "inbox").map(\.id).contains("done"))
    }

    @Test func eventsFilterVisibilityAndRangeBoundaries() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(
            cursor: "c",
            events: [
                Fixtures.event(id: "in", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z"),
                Fixtures.event(id: "declined", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z", responseStatus: "declined"),
                Fixtures.event(id: "cancelled", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z", status: "cancelled"),
                Fixtures.event(id: "unselected", calendarId: "hidden", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z"),
                Fixtures.event(id: "no-response", start: "2026-11-09T12:00:00Z", end: "2026-11-09T13:00:00Z", responseStatus: nil),
                // Ends exactly at range start → excluded.
                Fixtures.event(id: "ends-at-start", start: "2026-11-08T23:00:00Z", end: "2026-11-09T00:00:00Z"),
                // Starts exactly at range end → excluded.
                Fixtures.event(id: "starts-at-end", start: "2026-11-10T00:00:00Z", end: "2026-11-10T01:00:00Z"),
                // Straddles range start → included.
                Fixtures.event(id: "straddles", start: "2026-11-08T23:30:00Z", end: "2026-11-09T00:30:00Z"),
                // All-day spanning the day → included.
                Fixtures.event(id: "allday", start: "2026-11-09T00:00:00Z", end: "2026-11-10T00:00:00Z", allDay: true),
            ],
            calendars: [Fixtures.calendar(id: "cal", selected: true), Fixtures.calendar(id: "hidden", selected: false)]))

        let day = Fixtures.instant("2026-11-09T00:00:00Z")..<Fixtures.instant("2026-11-10T00:00:00Z")
        #expect(try db.events(in: day).map(\.id) == ["straddles", "allday", "in", "no-response"])
    }

    @Test func placementsOverlapRange() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", placements: [
            Fixtures.placement(id: "before", taskId: "t", start: "2026-11-08T22:00:00Z", end: "2026-11-09T00:00:00Z"),
            Fixtures.placement(id: "straddle", taskId: "t", start: "2026-11-08T23:00:00Z", end: "2026-11-09T01:00:00Z"),
            Fixtures.placement(id: "inside", taskId: "t", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z"),
            Fixtures.placement(id: "after", taskId: "t", start: "2026-11-10T00:00:00Z", end: "2026-11-10T01:00:00Z"),
        ]))
        let day = Fixtures.instant("2026-11-09T00:00:00Z")..<Fixtures.instant("2026-11-10T00:00:00Z")
        #expect(try db.placements(in: day).map(\.id) == ["straddle", "inside"])
    }

    // MARK: 4. Pending queue collapsing

    @Test func saveTaskTwiceCollapsesToOnePendingRow() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "t1")
        try db.saveTask(task, now: Fixtures.instant("2026-11-08T10:00:00Z"))
        task.title = "second"
        try db.saveTask(task, now: Fixtures.instant("2026-11-08T10:01:00Z"))
        try db.saveTask(Fixtures.task(id: "t2"), now: Fixtures.instant("2026-11-08T10:02:00Z"))

        let pending = try db.pendingWrites()
        #expect(pending.count == 2)
        #expect(pending.map(\.entityId) == ["t1", "t2"])
        #expect(pending.allSatisfy { $0.op == .put && $0.entity == .task })

        // The surviving t1 row carries the latest body and the latest seq (it is re-queued, not updated in place).
        let t1 = try #require(pending.first)
        let body = try JSONCoding.decoder.decode(TaskWrite.self, from: try #require(t1.body))
        #expect(body.title == "second")
        #expect(try db.task(id: "t1")?.title == "second")
        #expect(try db.task(id: "t1")?.updatedAt == Fixtures.instant("2026-11-08T10:01:00Z"))
        #expect(pending.map { $0.seq ?? -1 } == pending.map { $0.seq ?? -1 }.sorted())
    }

    @Test func deleteAfterSaveLeavesSingleDeleteRow() throws {
        let db = try AppDatabase.inMemory()
        try db.saveTask(Fixtures.task(id: "t1"), now: Fixtures.t0)
        let deletedAt = Fixtures.instant("2026-11-08T10:05:00Z")
        try db.deleteTask(id: "t1", now: deletedAt)

        let pending = try db.pendingWrites()
        #expect(pending.count == 1)
        #expect(pending.first?.op == .delete)
        #expect(pending.first?.entityId == "t1")
        #expect(pending.first?.body == nil)

        let task = try #require(try db.task(id: "t1"))
        #expect(task.deletedAt == deletedAt)
        #expect(task.updatedAt == deletedAt)
        #expect(try db.openTasks().isEmpty)
    }

    @Test func completeAndReopenGoThroughSaveTask() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", tasks: [Fixtures.task(id: "t1")]))
        let doneAt = Fixtures.instant("2026-11-08T16:00:00Z")
        try db.completeTask(id: "t1", at: doneAt)
        var task = try #require(try db.task(id: "t1"))
        #expect(task.completedAt == doneAt)
        #expect(task.completedMinutes == task.durationMinutes)
        #expect(try db.openTasks().isEmpty)

        try db.reopenTask(id: "t1", now: Fixtures.instant("2026-11-08T16:30:00Z"))
        task = try #require(try db.task(id: "t1"))
        #expect(task.completedAt == nil)
        #expect(task.completedMinutes == 0)
        #expect(try db.openTasks().map(\.id) == ["t1"])

        let pending = try db.pendingWrites()
        #expect(pending.count == 1)
        #expect(pending.first?.op == .put)
    }

    @Test func projectAndScheduleWritesQueueAndCollapse() throws {
        let db = try AppDatabase.inMemory()
        try db.saveSchedule(Fixtures.schedule(id: "s1"), now: Fixtures.t0)
        try db.saveProject(Fixtures.project(id: "p1", scheduleId: "s1"), now: Fixtures.t0)
        try db.saveProject(Fixtures.project(id: "p1", scheduleId: "s1", sortOrder: 5), now: Fixtures.t0)
        try db.deleteSchedule(id: "s1", now: Fixtures.t0)

        let pending = try db.pendingWrites()
        #expect(pending.map { "\($0.entity.rawValue):\($0.entityId):\($0.op.rawValue)" } == ["project:p1:put", "schedule:s1:delete"])
        #expect(try db.projects().first?.sortOrder == 5)
        #expect(try db.schedules().isEmpty, "deleted schedules are hidden from schedules()")
        let body = try JSONCoding.decoder.decode(ProjectWrite.self, from: try #require(pending.first?.body))
        #expect(body.sortOrder == 5)

        try db.deleteProject(id: "p1", now: Fixtures.t0)
        #expect(try db.projects().isEmpty)
        #expect(try db.pendingWrites().filter { $0.entity == .project }.map(\.op) == [.delete])
    }

    // MARK: 7. Agenda

    @Test func agendaJoinsPlacementsToTasksAndKeepsOnlyThatDay() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(
            cursor: "c",
            projects: [Fixtures.project()],
            tasks: [Fixtures.task(id: "t1", title: "Write report"), Fixtures.task(id: "t2", title: "Call")],
            events: [
                Fixtures.event(id: "today", start: "2026-11-09T15:00:00Z", end: "2026-11-09T16:00:00Z"),
                Fixtures.event(id: "tomorrow", start: "2026-11-10T15:00:00Z", end: "2026-11-10T16:00:00Z"),
                Fixtures.event(id: "yesterday", start: "2026-11-08T15:00:00Z", end: "2026-11-08T16:00:00Z"),
            ],
            placements: [
                Fixtures.placement(id: "p1", taskId: "t1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z"),
                Fixtures.placement(id: "p2", taskId: "t2", start: "2026-11-09T09:00:00Z", end: "2026-11-09T09:30:00Z"),
                Fixtures.placement(id: "p3", taskId: "t1", start: "2026-11-10T09:00:00Z", end: "2026-11-10T10:00:00Z"),
                // Orphan placement: no such task locally → dropped from the agenda.
                Fixtures.placement(id: "p4", taskId: "missing", start: "2026-11-09T12:00:00Z", end: "2026-11-09T13:00:00Z"),
            ],
            calendars: [Fixtures.calendar()]))

        let agenda = try db.agenda(for: Fixtures.instant("2026-11-09T13:37:00Z"), calendar: Fixtures.utc)
        #expect(agenda.day == Fixtures.instant("2026-11-09T00:00:00Z"))
        #expect(agenda.events.map(\.id) == ["today"])
        #expect(agenda.placements.map(\.placement.id) == ["p2", "p1"])
        #expect(agenda.placements.map(\.task.title) == ["Call", "Write report"])

        // The widgets' range query joins the same way; the orphan is dropped there too.
        let twoDays = Fixtures.instant("2026-11-09T00:00:00Z")..<Fixtures.instant("2026-11-11T00:00:00Z")
        #expect(try db.scheduledBlocks(in: twoDays).map(\.placement.id) == ["p2", "p1", "p3"])

        // Grouping keeps every placement, orphans included, ordered by start within a task.
        let byTask = try db.placementsByTask()
        #expect(byTask["t1"]?.map(\.id) == ["p1", "p3"])
        #expect(byTask["t2"]?.map(\.id) == ["p2"])
        #expect(byTask["missing"]?.map(\.id) == ["p4"])
    }

    // MARK: Observation

    @Test func observeEmitsInitialAndChangedValues() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", tasks: [Fixtures.task(id: "t1")]))

        var iterator = db.observe { db in
            try TaskItem.filter(Column("deletedAt") == nil).order(Column("id")).fetchAll(db).map(\.id)
        }.makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial == ["t1"])

        try db.saveTask(Fixtures.task(id: "t2"), now: Fixtures.t0)
        let changed = try await iterator.next()
        #expect(changed == ["t1", "t2"])
    }
}
