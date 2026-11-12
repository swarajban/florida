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
        for expected in ["schedule", "category", "task", "placement", "event", "googleAccount", "calendar", "syncState", "pendingWrite"] {
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

    @Test func v1StoreMigratesKeepingItsRows() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO calendar (id, accountId, googleId, summary, accessRole, selected, updatedAt)
                VALUES ('cal', 'acct', 'g-cal', 'Work', 'owner', 1, '2026-11-08 00:00:00.000');
                INSERT INTO event (id, calendarId, googleId, status, summary, startAt, endAt, allDay, updatedAt)
                VALUES ('e1', 'cal', 'g-e1', 'confirmed', 'Standup', '2026-11-09 17:00:00.000', '2026-11-09 17:15:00.000', 0,
                        '2026-11-08 00:00:00.000');
                INSERT INTO task (id, categoryId, title, durationMinutes, priority, deadlineType, completedMinutes,
                                  createdAt, updatedAt)
                VALUES ('t1', 'inbox', 'Write report', 60, 'high', 'none', 0, '2026-11-08 00:00:00.000', '2026-11-08 00:00:00.000');
                INSERT INTO pendingWrite (entity, entityId, op, body, createdAt) VALUES ('task', 't1', 'put', NULL, '2026-11-08 00:00:00.000');
                INSERT INTO syncState (key, value) VALUES ('cursor', '2026-11-08T00:00:00.000Z');
                """)
        }

        let db = try AppDatabase(writer: queue)
        let applied = try queue.read { db in try AppDatabase.migrator.appliedMigrations(db) }
        #expect(applied == ["v1", "v2", "v3", "v4", "v5", "v6", "v7-calendar-blocking", "v8-event-blocks-day"])
        // Rows that predate the context column read as the default.
        #expect(try db.task(id: "t1")?.context == .computer)
        #expect(try db.routineBlocks() == [] && db.userSettings() == nil)
        // And those that predate projects are in none, with nothing planned around them.
        #expect(try db.task(id: "t1")?.projectId == nil && db.task(id: "t1")?.attention == nil)
        #expect(try db.projects() == [] && db.dayOverrides() == [] && db.planSummary() == PlanSummary())

        let event = try #require(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc).first)
        #expect(event.id == "e1" && event.summary == "Standup")
        #expect(event.startAt == Fixtures.instant("2026-11-09T17:00:00Z"))
        #expect(event.attendees == nil && event.organizer == nil && event.description == nil)
        #expect(try db.task(id: "t1")?.title == "Write report")
        #expect(try db.pendingWrites().map(\.entityId) == ["t1"])
        #expect(try db.calendars().map(\.id) == ["cal"])
        #expect(try db.unscheduled() == [])
        // The cursor is cleared so the next pull brings the new event fields for existing rows.
        #expect(try db.cursor() == nil)

        // The migrated table takes the new columns.
        var detailed = event
        detailed.attendees = [EventAttendee(email: "me@example.com", responseStatus: "accepted", isSelf: true)]
        detailed.organizer = EventOrganizer(email: "boss@example.com")
        detailed.conferenceUrl = "https://meet.google.com/abc-defg-hij"
        try db.apply(SyncResponse(cursor: "c", events: [detailed], calendars: [Fixtures.calendar()]))
        #expect(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc) == [detailed])
    }

    @Test func eventAttendeesAndOrganizerAreJSONTextColumns() throws {
        let db = try AppDatabase.inMemory()
        var event = Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        event.attendees = [
            EventAttendee(email: "me@example.com", responseStatus: "accepted", isSelf: true),
            EventAttendee(email: "guest@example.com", displayName: "Guest", optional: true),
        ]
        event.organizer = EventOrganizer(email: "me@example.com", isSelf: true)
        event.description = "Notes"
        event.eventType = "default"
        event.recurringEventId = "series"
        event.icalUid = "uid@google.com"
        try db.apply(SyncResponse(cursor: "c", events: [event], calendars: [Fixtures.calendar()]))

        #expect(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc) == [event])
        let raw = try db.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT attendees, organizer FROM event WHERE id = 'e1'")
        }
        let attendeesJSON: String = try #require(raw?["attendees"])
        let organizerJSON: String = try #require(raw?["organizer"])
        #expect(try JSONDecoder().decode([EventAttendee].self, from: Data(attendeesJSON.utf8)) == event.attendees)
        #expect(organizerJSON.contains("\"self\":true"))
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
        try db.saveCategory(Fixtures.category(), now: Fixtures.t0)
        #expect(try db.categories().count == 1)
    }

    // MARK: 2. apply(SyncResponse)

    @Test func applySyncResponseInsertsReplacesAndTombstones() throws {
        let db = try AppDatabase.inMemory()
        let first = SyncResponse(
            cursor: "2026-11-08T10:00:00.000Z",
            schedules: [Fixtures.schedule()],
            categories: [Fixtures.category()],
            tasks: [Fixtures.task(id: "t1"), Fixtures.task(id: "t2")],
            events: [Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")],
            placements: [Fixtures.placement(id: "p1", taskId: "t1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z")],
            accounts: [Fixtures.account()],
            calendars: [Fixtures.calendar(id: "cal"), Fixtures.calendar(id: "old")])
        try db.apply(first)

        #expect(try db.schedules().map(\.id) == ["work"])
        #expect(try db.categories().map(\.id) == ["inbox"])
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

        // Schedules and categories were absent from the second diff and must survive.
        #expect(try db.schedules().count == 1)
        #expect(try db.categories().count == 1)
    }

    @Test func applySyncResponseSkipsRowsWithPendingLocalWrites() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c1", categories: [Fixtures.category()], tasks: [Fixtures.task(id: "t1"), Fixtures.task(id: "t2")]))

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

    @Test func unscheduledIsReplacedWholesaleBySyncsAndSchedulerResults() throws {
        let db = try AppDatabase.inMemory()
        let at = Fixtures.instant("2026-11-08T09:00:00Z")
        try db.apply(SyncResponse(cursor: "c1", unscheduled: [
            UnscheduledTask(taskId: "t2", reason: "no_fit_in_horizon", unplacedMinutes: 60, computedAt: at),
            UnscheduledTask(taskId: "t1", reason: "unknown_schedule", unplacedMinutes: 30, computedAt: at),
        ]))
        #expect(try db.unscheduled().map(\.taskId) == ["t1", "t2"])

        // A scheduler result replaces the table and stamps its rows with the given time.
        let computedAt = Fixtures.instant("2026-11-08T15:00:00Z")
        try db.apply(SchedulingResult(unscheduled: [
            .init(taskId: "t3", reason: "no_fit_before_hard_deadline", unplacedMinutes: 15),
        ]), computedAt: computedAt)
        #expect(try db.unscheduled() == [
            UnscheduledTask(taskId: "t3", reason: "no_fit_before_hard_deadline", unplacedMinutes: 15, computedAt: computedAt),
        ])

        // A sync from a server without the field empties it, like placements.
        try db.apply(SyncResponse(cursor: "c2"))
        #expect(try db.unscheduled() == [])
    }

    @Test func suggestionsAreReplacedWholesaleAndStayOutOfThePlan() throws {
        let db = try AppDatabase.inMemory()
        let evening = RoutineBlock(
            id: "evening", name: "Evening", days: [1, 2, 3, 4], start: "20:00", end: "23:00",
            allows: [.computer, .home], optional: true, createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        let at = Fixtures.instant("2026-11-09T17:00:00Z")
        func suggestion(_ id: String, task: String, start: String, end: String) -> OptionalPlacement {
            OptionalPlacement(
                id: id, taskId: task, blockId: "evening", startAt: Fixtures.instant(start), endAt: Fixtures.instant(end),
                computedAt: at)
        }
        // Sent out of order; the same task is suggested on two evenings.
        let tuesday = suggestion("o2", task: "t1", start: "2026-11-11T04:00:00Z", end: "2026-11-11T05:00:00Z")
        let monday = suggestion("o1", task: "t1", start: "2026-11-10T04:00:00Z", end: "2026-11-10T05:00:00Z")
        try db.apply(SyncResponse(
            cursor: "c1", routineBlocks: [evening], categories: [Fixtures.category()], tasks: [Fixtures.task(id: "t1")],
            optionalPlacements: [tuesday, monday]))

        #expect(try db.routineBlocks().map(\.optional) == [true])
        #expect(try db.optionalPlacements() == [monday, tuesday])
        // Monday evening holds a suggestion, but nothing is scheduled there.
        #expect(try db.placements(in: Fixtures.allTime) == [])
        #expect(try db.scheduledBlocks(in: Fixtures.allTime) == [])

        // A scheduler result replaces the table and stamps its rows.
        let computedAt = Fixtures.instant("2026-11-09T18:00:00Z")
        try db.apply(SchedulingResult(optional: [
            .init(taskId: "t1", blockId: "evening", start: Fixtures.instant("2026-11-12T04:00:00Z"),
                  end: Fixtures.instant("2026-11-12T04:30:00Z")),
        ]), computedAt: computedAt)
        let rows = try db.optionalPlacements()
        #expect(rows.map(\.startAt) == [Fixtures.instant("2026-11-12T04:00:00Z")])
        #expect(rows.map(\.computedAt) == [computedAt] && rows.map(\.blockId) == ["evening"])

        // A sync from a server without the field empties it, like placements.
        try db.apply(SyncResponse(cursor: "c2"))
        #expect(try db.optionalPlacements() == [])
    }

    @Test func applySyncResponseStoresTheRoutineSettingsContextAndArea() throws {
        let db = try AppDatabase.inMemory()
        func block(_ id: String, days: [Int], start: String, allows: [TaskContext], deletedAt: Date? = nil) -> RoutineBlock {
            RoutineBlock(
                id: id, name: id, days: days, start: start, end: "16:20", allows: allows,
                createdAt: Fixtures.t0, updatedAt: Fixtures.t0, deletedAt: deletedAt)
        }
        let settings = UserSettings(id: "me", timeZone: "America/Los_Angeles", updatedAt: Fixtures.t0)
        var errand = Fixtures.task(id: "t1")
        errand.context = .errand
        var engineering = Fixtures.category(id: "eng")
        engineering.area = .work
        // Sent out of week order: Wednesday, Sunday, Monday afternoon, Monday morning.
        let wednesday = block("office-wed", days: [3], start: "09:00", allows: [.computer, .office])
        let sunday = block("sunday", days: [0], start: "09:00", allows: [])
        let mondayLate = block("home-late", days: [5, 1], start: "13:00", allows: [.computer])
        let mondayEarly = block("home", days: [1, 4, 5], start: "09:00", allows: [.computer, .errand, .home])
        try db.apply(SyncResponse(
            cursor: "c1", settings: settings, routineBlocks: [wednesday, sunday, mondayLate, mondayEarly],
            categories: [engineering, Fixtures.category()], tasks: [errand]))

        #expect(try db.userSettings() == settings)
        #expect(try db.routineBlocks() == [mondayEarly, mondayLate, wednesday, sunday], "Monday first, then by start")
        #expect(try db.task(id: "t1")?.context == .errand)
        #expect(try db.categories().map(\.area) == [nil, .work], "Inbox first, whatever order the server sent")
        let allows = try db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT allows FROM routineBlock WHERE id = 'home'")
        }
        #expect(try JSONDecoder().decode([TaskContext].self, from: Data(try #require(allows).utf8)) == [.computer, .errand, .home])

        // An incremental pull: one block tombstoned, the rest untouched, settings resent whole.
        let moved = UserSettings(id: "me", timeZone: "America/New_York", updatedAt: Fixtures.t0)
        try db.apply(SyncResponse(
            cursor: "c2", settings: moved,
            routineBlocks: [block("office-wed", days: [3], start: "09:00", allows: [], deletedAt: Fixtures.t0)]))
        #expect(try db.routineBlocks().map(\.id) == ["home", "home-late", "sunday"])
        #expect(try db.userSettings() == moved)

        // A server that has not been seeded sends null settings.
        try db.apply(SyncResponse(cursor: "c3"))
        #expect(try db.userSettings() == nil)
        #expect(try db.routineBlocks().count == 3)
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
        #expect(try db.tasks(inCategory: "inbox").map(\.id).contains("done"))
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
        #expect(try db.events(in: day, calendar: Fixtures.utc).map(\.id) == ["straddles", "allday", "in", "no-response"])
    }

    /// Stored all-day dates are UTC midnights. Pacific is behind UTC (Nov 10 00:00Z is Nov 9 16:00
    /// local) and Tokyo ahead of it (Nov 10 09:00 local), so each catches a different wrong answer.
    @Test(arguments: ["America/Los_Angeles", "Asia/Tokyo"])
    func allDayEventsAppearOnlyOnTheirLocalDates(_ zone: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: d))! }
        func ids(on d: Int) throws -> [String] {
            try db.events(in: day(d)..<day(d + 1), calendar: calendar).map(\.id)
        }

        let db = try AppDatabase.inMemory()
        // The timed event runs 23:30 Nov 10 → 00:30 Nov 11 local in either zone.
        let straddleStart = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 23, minute: 30))!
        var straddle = Fixtures.event(id: "late", start: "2026-01-01T00:00:00Z", end: "2026-01-01T00:00:00Z")
        straddle.startAt = straddleStart
        straddle.endAt = straddleStart.addingTimeInterval(3600)
        try db.apply(SyncResponse(
            cursor: "c",
            events: [
                Fixtures.event(id: "nov10", start: "2026-11-10T00:00:00Z", end: "2026-11-11T00:00:00Z", allDay: true),
                Fixtures.event(id: "nov12-13", start: "2026-11-12T00:00:00Z", end: "2026-11-14T00:00:00Z", allDay: true),
                straddle,
            ],
            calendars: [Fixtures.calendar()]))

        #expect(try ids(on: 9) == [])
        #expect(try ids(on: 10) == ["nov10", "late"])
        #expect(try ids(on: 11) == ["late"])
        #expect(try ids(on: 12) == ["nov12-13"])
        #expect(try ids(on: 13) == ["nov12-13"])
        #expect(try ids(on: 14) == [])

        // A week view's range and the agenda go through the same comparison.
        #expect(try db.events(in: day(9)..<day(16), calendar: calendar).map(\.id).sorted() == ["late", "nov10", "nov12-13"])
        let agenda = try db.agenda(for: day(9).addingTimeInterval(12 * 3600), calendar: calendar)
        #expect(agenda.events.isEmpty)
        #expect(try db.agenda(for: day(10), calendar: calendar).events.map(\.id) == ["nov10", "late"])
    }

    @Test func agendaOfADayWhoseMidnightDSTSkipsEndsAtTheNextMidnight() throws {
        // Cuba's DST starts 2026-03-08 at 00:00, so that Sunday begins at 01:00 and is 23 hours long.
        var havana = Calendar(identifier: .gregorian)
        havana.timeZone = TimeZone(identifier: "America/Havana")!
        let sunday = havana.startOfDay(for: havana.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!)
        try #require(havana.component(.hour, from: sunday) == 1, "expected the Havana DST change at midnight")

        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(
            cursor: "c",
            events: [
                Fixtures.event(id: "sun", start: "2026-03-08T00:00:00Z", end: "2026-03-09T00:00:00Z", allDay: true),
                Fixtures.event(id: "mon", start: "2026-03-09T00:00:00Z", end: "2026-03-10T00:00:00Z", allDay: true),
                // 00:30–01:00 Monday (UTC-4 after the change): on Sunday when its end is 01:00 + 24 h.
                Fixtures.event(id: "mon-early", start: "2026-03-09T04:30:00Z", end: "2026-03-09T05:00:00Z"),
            ],
            calendars: [Fixtures.calendar()]))

        #expect(try db.agenda(for: sunday, calendar: havana).events.map(\.id) == ["sun"])
        #expect(try db.agenda(for: sunday.addingTimeInterval(23 * 3600), calendar: havana).events.map(\.id) == ["mon", "mon-early"])
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

    @Test func completionStampsFollowTheActualLocalDayAndSurviveRescheduling() throws {
        let db = try AppDatabase.inMemory()
        let at = Fixtures.instant("2026-11-09T07:57:00Z") // Nov 8, 11:57 PM in Los Angeles
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: at)!
        let oldSlot = Placement(id: "p", taskId: "later", startAt: tomorrow, endAt: tomorrow.addingTimeInterval(3600), pinned: false, computedAt: at)
        try db.apply(SyncResponse(cursor: "c", tasks: [Fixtures.task(id: "later"), Fixtures.task(id: "unscheduled")], placements: [oldSlot]))
        try db.completeTask(id: "later", at: at)
        try db.completeTask(id: "unscheduled", at: at.addingTimeInterval(60))
        let agenda = try db.agenda(for: at, calendar: calendar)
        #expect(agenda.completedTasks.map(\.id) == ["later", "unscheduled"])
        #expect(agenda.completedTasks.first?.completedAt == at)
        #expect(agenda.placements.isEmpty)
        #expect(try db.agenda(for: tomorrow, calendar: calendar).placements.isEmpty, "the stale future slot disappears immediately")
        #expect(try db.agenda(for: tomorrow, calendar: calendar).completedTasks.isEmpty)

        try db.apply(SyncResponse(cursor: "c2", placements: []))
        #expect(try db.agenda(for: at, calendar: calendar).completedTasks.map(\.id) == ["later", "unscheduled"])
        try db.reopenTask(id: "later", now: at.addingTimeInterval(90))
        try db.deleteTask(id: "unscheduled", now: at.addingTimeInterval(100))
        #expect(try db.agenda(for: at, calendar: calendar).completedTasks.isEmpty)
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
        #expect(pending.first?.op == .patch)
    }

    @Test func categoryAndScheduleWritesQueueAndCollapse() throws {
        let db = try AppDatabase.inMemory()
        try db.saveSchedule(Fixtures.schedule(id: "s1"), now: Fixtures.t0)
        try db.saveCategory(Fixtures.category(id: "p1", scheduleId: "s1"), now: Fixtures.t0)
        try db.saveCategory(Fixtures.category(id: "p1", scheduleId: "s1", sortOrder: 5), now: Fixtures.t0)
        try db.deleteSchedule(id: "s1", now: Fixtures.t0)

        let pending = try db.pendingWrites()
        #expect(pending.map { "\($0.entity.rawValue):\($0.entityId):\($0.op.rawValue)" } == ["category:p1:put", "schedule:s1:delete"])
        #expect(try db.categories().first?.sortOrder == 5)
        #expect(try db.schedules().isEmpty, "deleted schedules are hidden from schedules()")
        let body = try JSONCoding.decoder.decode(CategoryWrite.self, from: try #require(pending.first?.body))
        #expect(body.sortOrder == 5)

        try db.deleteCategory(id: "p1", now: Fixtures.t0)
        #expect(try db.categories().isEmpty)
        #expect(try db.pendingWrites().filter { $0.entity == .category }.map(\.op) == [.delete])
    }

    // MARK: 5. Event writes

    @Test(arguments: [false, true]) func saveEventQueuesOnePutAndShowsTheRowAtOnce(repeating: Bool) throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", calendars: [Fixtures.calendar()]))
        // A new event has no Google id until the server's copy arrives.
        var event = Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z", responseStatus: nil)
        event.googleId = ""
        event.location = "Room 4"
        let recurrence = repeating ? EventRecurrence(frequency: .weekly, interval: 2, timeZone: "America/Los_Angeles", count: 12) : nil
        try db.saveEvent(event, recurrence: recurrence, now: Fixtures.instant("2026-11-08T10:00:00Z"))
        event.summary = "renamed"
        try db.saveEvent(event, now: Fixtures.instant("2026-11-08T10:01:00Z"))

        let pending = try db.pendingWrites()
        #expect(pending.map { "\($0.entity.rawValue):\($0.entityId):\($0.op.rawValue)" } == ["event:e1:put"])
        let body = try JSONCoding.decoder.decode(EventWrite.self, from: try #require(pending.first?.body))
        #expect(body == EventWrite(
            calendarId: "cal", summary: "renamed", location: "Room 4", startAt: Fixtures.instant("2026-11-09T10:00:00Z"),
            endAt: Fixtures.instant("2026-11-09T11:00:00Z"), allDay: false, recurrence: recurrence))

        let stored = try #require(try db.event(id: "e1"))
        #expect(stored.summary == "renamed")
        #expect(stored.googleId == "")
        #expect(stored.updatedAt == Fixtures.instant("2026-11-08T10:01:00Z"))
        #expect(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc).map(\.id) == ["e1"])
        #expect(try db.agenda(for: Fixtures.instant("2026-11-09T12:00:00Z"), calendar: Fixtures.utc).events.map(\.id) == ["e1"])
    }

    @Test func saveEventWithoutTimesThrowsAndQueuesNothing() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", calendars: [Fixtures.calendar()]))
        var event = Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        event.endAt = nil

        #expect(throws: AppDatabase.WriteError.eventWithoutTimes(id: "e1")) {
            try db.saveEvent(event, now: Fixtures.t0)
        }
        #expect(try db.event(id: "e1") == nil, "nothing is stored")
        #expect(try db.pendingWrites().isEmpty, "nothing is queued for the server to refuse")
    }

    @Test func moveEventSeriesShiftsEveryLiveInstanceAndQueuesOneSeriesPut() throws {
        let db = try AppDatabase.inMemory()
        func instance(_ id: String, calendarId: String = "cal", series: String? = "weekly", start: String, end: String) -> CalendarEvent {
            var event = Fixtures.event(id: id, calendarId: calendarId, start: start, end: end)
            event.recurringEventId = series
            return event
        }
        try db.apply(SyncResponse(
            cursor: "c",
            events: [
                instance("w1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T17:30:00Z"),
                instance("w2", start: "2026-11-16T17:00:00Z", end: "2026-11-16T17:30:00Z"),
                // Moved on its own earlier: it shifts by as much as the rest.
                instance("w3", start: "2026-11-23T19:00:00Z", end: "2026-11-23T20:00:00Z"),
                instance("gone", start: "2026-11-30T17:00:00Z", end: "2026-11-30T17:30:00Z"),
                instance("other-series", series: "daily", start: "2026-11-16T17:00:00Z", end: "2026-11-16T17:30:00Z"),
                instance("other-calendar", calendarId: "cal2", start: "2026-11-16T17:00:00Z", end: "2026-11-16T17:30:00Z"),
                instance("single", series: nil, start: "2026-11-16T17:00:00Z", end: "2026-11-16T17:30:00Z"),
            ],
            calendars: [Fixtures.calendar(), Fixtures.calendar(id: "cal2")]))
        // Deleted here and not yet pushed: its tombstone stays where it was.
        try db.deleteEvent(id: "gone", now: Fixtures.t0)
        let now = Fixtures.instant("2026-11-08T10:00:00Z")

        // w2 is dragged 90 minutes later and made 45 minutes long.
        try db.moveEventSeries(
            instanceId: "w2", start: Fixtures.instant("2026-11-16T18:30:00Z"), end: Fixtures.instant("2026-11-16T19:15:00Z"), now: now)

        func times(_ id: String) throws -> [Date?] {
            let event = try #require(try db.event(id: id))
            return [event.startAt, event.endAt]
        }
        #expect(try times("w1") == [Fixtures.instant("2026-11-09T18:30:00Z"), Fixtures.instant("2026-11-09T19:15:00Z")])
        #expect(try times("w2") == [Fixtures.instant("2026-11-16T18:30:00Z"), Fixtures.instant("2026-11-16T19:15:00Z")])
        #expect(try times("w3") == [Fixtures.instant("2026-11-23T20:30:00Z"), Fixtures.instant("2026-11-23T21:15:00Z")])
        for untouched in ["other-series", "other-calendar", "single"] {
            #expect(try times(untouched) == [Fixtures.instant("2026-11-16T17:00:00Z"), Fixtures.instant("2026-11-16T17:30:00Z")])
        }
        #expect(try times("gone") == [Fixtures.instant("2026-11-30T17:00:00Z"), Fixtures.instant("2026-11-30T17:30:00Z")])

        // One write, for the dragged instance; the server moves the rest from it.
        let pending = try db.pendingWrites()
        #expect(pending.map { "\($0.entity.rawValue):\($0.entityId):\($0.op.rawValue)" }.sorted() == ["event:gone:delete", "event:w2:put"])
        let body = try JSONCoding.decoder.decode(EventWrite.self, from: try #require(pending.first { $0.entityId == "w2" }?.body))
        #expect(body.scope == .series)
        #expect(body.startAt == Fixtures.instant("2026-11-16T18:30:00Z"))
        #expect(body.endAt == Fixtures.instant("2026-11-16T19:15:00Z"))

        // An RSVP on the dragged instance before the push still tells the server to move the series.
        var answered = try #require(try db.event(id: "w2"))
        answered.responseStatus = "accepted"
        try db.saveEvent(answered, now: now)
        let resent = try JSONCoding.decoder.decode(
            EventWrite.self, from: try #require(try db.pendingWrites().first { $0.entityId == "w2" }?.body))
        #expect(resent.scope == .series)
        #expect(resent.responseStatus == "accepted")

        // An event that does not repeat moves alone, and a missing one is refused.
        try db.moveEventSeries(
            instanceId: "single", start: Fixtures.instant("2026-11-16T15:00:00Z"), end: Fixtures.instant("2026-11-16T15:30:00Z"), now: now)
        #expect(try times("single") == [Fixtures.instant("2026-11-16T15:00:00Z"), Fixtures.instant("2026-11-16T15:30:00Z")])
        #expect(try times("other-series") == [Fixtures.instant("2026-11-16T17:00:00Z"), Fixtures.instant("2026-11-16T17:30:00Z")])
        #expect(throws: AppDatabase.WriteError.eventWithoutTimes(id: "nope")) {
            try db.moveEventSeries(instanceId: "nope", start: now, end: now.addingTimeInterval(60), now: now)
        }
    }

    @Test func deleteEventHidesTheRowAtOnceAndLeavesOneDeleteRow() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(
            cursor: "c",
            events: [
                Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z"),
                Fixtures.event(id: "e2", start: "2026-11-09T12:00:00Z", end: "2026-11-09T13:00:00Z"),
            ],
            calendars: [Fixtures.calendar()]))
        var moved = try #require(try db.event(id: "e1"))
        moved.startAt = Fixtures.instant("2026-11-09T14:00:00Z")
        try db.saveEvent(moved, now: Fixtures.t0)
        let deletedAt = Fixtures.instant("2026-11-08T10:05:00Z")
        try db.deleteEvent(id: "e1", now: deletedAt)

        let pending = try db.pendingWrites()
        #expect(pending.count == 1, "the delete replaces the queued put")
        #expect(pending.first?.entity == .event)
        #expect(pending.first?.op == .delete)
        #expect(pending.first?.entityId == "e1")
        #expect(pending.first?.body == nil)

        let row = try #require(try db.event(id: "e1"))
        #expect(row.deletedAt == deletedAt)
        #expect(row.updatedAt == deletedAt)
        #expect(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc).map(\.id) == ["e2"])
        #expect(try db.agenda(for: Fixtures.instant("2026-11-09T12:00:00Z"), calendar: Fixtures.utc).events.map(\.id) == ["e2"])
    }

    @Test func applySyncResponseSkipsEventsWithPendingLocalWrites() throws {
        let db = try AppDatabase.inMemory()
        func event(_ id: String, start: String, end: String, summary: String? = nil) -> CalendarEvent {
            var event = Fixtures.event(id: id, start: start, end: end)
            if let summary { event.summary = summary }
            return event
        }
        try db.apply(SyncResponse(
            cursor: "c1",
            events: [
                event("e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z"),
                event("e2", start: "2026-11-09T12:00:00Z", end: "2026-11-09T13:00:00Z"),
                event("e3", start: "2026-11-09T14:00:00Z", end: "2026-11-09T15:00:00Z"),
            ],
            calendars: [Fixtures.calendar()]))

        // A local edit of e1 and a local delete of e2, neither pushed yet.
        var local = try #require(try db.event(id: "e1"))
        local.summary = "local edit"
        try db.saveEvent(local, now: Fixtures.instant("2026-11-08T13:00:00Z"))
        try db.deleteEvent(id: "e2", now: Fixtures.instant("2026-11-08T13:00:00Z"))

        // The server sends its own e1, a live e2 and a renamed e3: only e3 may change.
        let serverE1 = event("e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z", summary: "server edit")
        try db.apply(SyncResponse(
            cursor: "c2",
            events: [
                serverE1,
                event("e2", start: "2026-11-09T12:00:00Z", end: "2026-11-09T13:00:00Z", summary: "still alive"),
                event("e3", start: "2026-11-09T14:00:00Z", end: "2026-11-09T15:00:00Z", summary: "renamed"),
            ],
            calendars: [Fixtures.calendar()]))

        #expect(try db.event(id: "e1")?.summary == "local edit")
        #expect(try db.event(id: "e2")?.deletedAt != nil)
        #expect(try db.event(id: "e3")?.summary == "renamed")
        #expect(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc).map(\.id) == ["e1", "e3"])
        #expect(try db.cursor() == "c2")

        // Once the queue has drained the server's version applies again.
        for write in try db.pendingWrites() {
            try db.removePendingWrite(seq: try #require(write.seq))
        }
        try db.apply(SyncResponse(cursor: "c3", events: [serverE1], calendars: [Fixtures.calendar()]))
        #expect(try db.event(id: "e1")?.summary == "server edit")
    }

    // MARK: 7. Agenda

    @Test func agendaJoinsPlacementsToTasksAndKeepsOnlyThatDay() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(
            cursor: "c",
            categories: [Fixtures.category()],
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

    @Test func pinningATaskMovesItsBlockAtOnceAndUnpinningTakesItOffThePlan() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "t1")
        task.completedMinutes = 15
        let week = Fixtures.instant("2026-11-09T00:00:00Z")..<Fixtures.instant("2026-11-16T00:00:00Z")
        try db.apply(SyncResponse(
            cursor: "c",
            tasks: [task, Fixtures.task(id: "t2")],
            placements: [
                Fixtures.placement(id: "p1", taskId: "t1", start: "2026-11-11T17:00:00Z", end: "2026-11-11T17:45:00Z"),
                Fixtures.placement(id: "p2", taskId: "t2", start: "2026-11-10T18:00:00Z", end: "2026-11-10T19:00:00Z"),
            ],
            unscheduled: [UnscheduledTask(taskId: "t1", reason: "no_fit_in_horizon", unplacedMinutes: 30, computedAt: Fixtures.t0)]))

        // An edit that leaves the pin alone leaves the plan alone.
        task.title = "renamed"
        try db.saveTask(task, now: Fixtures.instant("2026-11-09T01:00:00Z"))
        #expect(try db.placements(in: week).map(\.id) == ["p2", "p1"])
        #expect(try db.unscheduled().map(\.taskId) == ["t1"])

        // Pinned: one block at the pin for the 45 minutes still to do, before the server answers.
        task.pinnedStart = Fixtures.instant("2026-11-10T04:00:00Z")
        try db.saveTask(task, now: Fixtures.instant("2026-11-09T02:00:00Z"))
        let pinned = try db.placements(in: week)
        #expect(pinned.map(\.taskId) == ["t1", "t2"])
        #expect(pinned.first?.startAt == Fixtures.instant("2026-11-10T04:00:00Z"))
        #expect(pinned.first?.endAt == Fixtures.instant("2026-11-10T04:45:00Z"))
        #expect(pinned.first?.pinned == true)
        #expect(pinned.last?.id == "p2", "other tasks keep their blocks")
        #expect(try db.unscheduled().isEmpty)

        // Unpinned (Undo): the block goes; the scheduler places the task again on its next run.
        task.pinnedStart = nil
        try db.saveTask(task, now: Fixtures.instant("2026-11-09T03:00:00Z"))
        #expect(try db.placements(in: week).map(\.id) == ["p2"])
    }

    @Test func aPullOlderThanAQueuedPinOrUnpinKeepsWhatTheUserSees() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "t1")
        let week = Fixtures.instant("2026-11-09T00:00:00Z")..<Fixtures.instant("2026-11-16T00:00:00Z")
        let pin = Fixtures.instant("2026-11-10T04:00:00Z")
        let serverPlan = [
            Fixtures.placement(id: "p1", taskId: "t1", start: "2026-11-11T17:00:00Z", end: "2026-11-11T18:00:00Z"),
            Fixtures.placement(id: "p2", taskId: "t2", start: "2026-11-10T18:00:00Z", end: "2026-11-10T19:00:00Z"),
        ]
        try db.apply(SyncResponse(cursor: "c", tasks: [task, Fixtures.task(id: "t2")], placements: serverPlan))

        // The pin is queued; a pull answered from before it still has t1 on Wednesday.
        task.pinnedStart = pin
        try db.saveTask(task, now: Fixtures.instant("2026-11-09T02:00:00Z"))
        try db.apply(SyncResponse(cursor: "c2", placements: serverPlan))
        let kept = try db.placements(in: week)
        #expect(kept.map(\.taskId) == ["t1", "t2"])
        #expect(kept.first?.startAt == pin)
        #expect(kept.first?.pinned == true)
        #expect(kept.last?.id == "p2", "tasks without a queued write take the pulled plan")

        // The server accepts the pin, then the unpin is queued; a pull from before it still has the pinned block.
        let accepted = try #require(try db.pendingWrites().first)
        try db.removePendingWrite(seq: try #require(accepted.seq))
        let pinnedPlan = [Placement(id: "p3", taskId: "t1", startAt: pin, endAt: pin.addingTimeInterval(3600), pinned: true, computedAt: Fixtures.t0), serverPlan[1]]
        try db.apply(SyncResponse(cursor: "c3", placements: pinnedPlan))
        #expect(try db.placements(in: week).map(\.id) == ["p3", "p2"], "an agreeing pull is stored as sent")

        task.pinnedStart = nil
        try db.saveTask(task, now: Fixtures.instant("2026-11-09T03:00:00Z"))
        try db.apply(SyncResponse(cursor: "c4", placements: pinnedPlan))
        #expect(try db.placements(in: week).map(\.id) == ["p2"])
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
