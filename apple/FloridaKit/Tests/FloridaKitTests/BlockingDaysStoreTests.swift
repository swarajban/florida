import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct BlockingDaysStoreTests {
    @Test func realStaysLeaveMondayOpenAndManualOverridesUpdateLocally() async throws {
        let db = try AppDatabase.inMemory()
        var calendar = Fixtures.utc
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var marshall = Fixtures.event(id: "marshall", start: "2026-11-13T00:00:00Z", end: "2026-11-17T00:00:00Z", allDay: true)
        marshall.autoBlocksDay = true
        marshall.blockingReason = "Your trip"
        var tomales = marshall
        tomales.id = "tomales"
        tomales.googleId = "tomales"
        tomales.endAt = Fixtures.instant("2026-11-16T00:00:00Z")
        try db.apply(SyncResponse(cursor: "c", events: [marshall, tomales], calendars: [Fixtures.calendar(selected: false)]))
        let first = Fixtures.instant("2026-11-13T08:00:00Z")
        for offset in 0...2 {
            let day = DateNavigation.shift(first, by: offset, calendar: calendar)
            let agenda = try db.agenda(for: day, calendar: calendar)
            #expect(agenda.events.isEmpty)
            #expect(Set(agenda.blockingAllDayEvents.map(\.id)) == (offset == 2 ? ["marshall"] : ["marshall", "tomales"]))
        }
        let monday = Fixtures.instant("2026-11-16T08:00:00Z")
        let range = monday..<Fixtures.instant("2026-11-17T08:00:00Z")
        var observation = db.observeBlockingAllDayEvents(in: range, calendar: calendar).makeAsyncIterator()
        #expect(try await observation.next() == [])
        #expect(try db.agenda(for: monday, calendar: calendar).blockingAllDayEvents.isEmpty)
        try db.setEventBlocksDay(id: "marshall", blocksDay: true)
        #expect(try await observation.next()?.map(\.id) == ["marshall"])
        try db.setEventBlocksDay(id: "marshall", blocksDay: false)
        #expect(try await observation.next() == [])
        #expect(try db.agenda(for: first, calendar: calendar).blockingAllDayEvents.map(\.id) == ["tomales"])
        try db.setEventBlocksDay(id: "marshall", blocksDay: nil)
        #expect(try await observation.next() == [])
        #expect(try db.agenda(for: monday, calendar: calendar).blockingAllDayEvents.isEmpty)
    }

    func holiday(_ id: String = "holiday") -> CalendarEvent {
        var event = Fixtures.event(id: id, start: "2026-11-01T00:00:00Z", end: "2026-11-03T00:00:00Z", allDay: true)
        event.autoBlocksDay = true
        event.blockingReason = "US public holiday."
        return event
    }

    @Test func migrationKeepsRowsAndManualOverridesAndFetchesJudgments() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v8-event-blocks-day")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO googleAccount (id, email, label, updatedAt) VALUES ('acct', 'me@example.com', 'personal', '2026-11-08 00:00:00.000');
                INSERT INTO event (id, calendarId, googleId, status, allDay, blocksDay, updatedAt)
                VALUES ('e', 'cal', 'g-e', 'confirmed', 1, 0, '2026-11-08 00:00:00.000');
                INSERT INTO syncState (key, value) VALUES ('cursor', 'old');
                """)
        }
        let db = try AppDatabase(writer: queue)
        let event = try #require(try db.event(id: "e"))
        #expect(event.blocksDay == false)
        #expect(event.autoBlocksDay == nil && event.blockingReason == nil)
        #expect(try db.accounts().first?.displayName == nil)
        #expect(try db.cursor() == nil)
    }

    @Test func taskSourceStoreUpgradeKeepsSourcesOverridesAndQueuedWrites() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v9-task-source")
        let source = try #require(TaskSource.from(url: "https://github.com/acme/app/issues/1"))
        let sourceJSON = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        let pendingBody = Data(#"{"title":"Keep queued edit"}"#.utf8)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO googleAccount (id, email, label, updatedAt)
                VALUES ('acct', 'me@example.com', 'personal', '2026-11-08 00:00:00.000');
                INSERT INTO calendar (id, accountId, googleId, summary, accessRole, selected, blocksScheduling, updatedAt)
                VALUES ('cal', 'acct', 'g-cal', 'Work', 'owner', 0, 1, '2026-11-08 00:00:00.000');
                INSERT INTO event (id, calendarId, googleId, status, allDay, blocksDay, updatedAt)
                VALUES ('e', 'cal', 'g-e', 'confirmed', 1, 0, '2026-11-08 00:00:00.000');
                INSERT INTO syncState (key, value) VALUES ('cursor', 'v9-cursor'), ('other', 'keep');
                """)
            try db.execute(sql: """
                INSERT INTO task (id, categoryId, title, durationMinutes, priority, deadlineType, completedMinutes,
                                  createdAt, updatedAt, source)
                VALUES ('linked', 'inbox', 'Keep task', 30, 'medium', 'none', 0,
                        '2026-11-08 00:00:00.000', '2026-11-08 00:00:00.000', ?)
                """, arguments: [sourceJSON])
            var pending = PendingWrite(entity: .task, entityId: "linked", op: .patch, body: pendingBody, createdAt: Fixtures.t0)
            try pending.insert(db)
        }
        let database = try AppDatabase(writer: queue)
        let task = try #require(try database.task(id: "linked"))
        let event = try #require(try database.event(id: "e"))
        let calendar = try #require(try database.calendars().first)
        #expect(task.title == "Keep task" && task.source == source)
        #expect(task.updatedAt == Fixtures.instant("2026-11-08T00:00:00Z"))
        #expect(event.blocksDay == false && event.autoBlocksDay == nil && event.blockingReason == nil)
        #expect(event.updatedAt == Fixtures.instant("2026-11-08T00:00:00Z"))
        #expect(!calendar.selected && calendar.blocksScheduling)
        #expect(try database.accounts().first?.displayName == nil)
        #expect(try database.cursor() == nil)
        #expect(try database.pendingWrites().count == 1)
        #expect(try database.pendingWrites().first?.body == pendingBody)
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT value FROM syncState WHERE key = 'other'") } == "keep")
        #expect(try queue.read { try AppDatabase.migrator.appliedMigrations($0).suffix(3) }
            == ["v9-task-source", "v10-automatic-day-blocking", "v11-someday-date-decision"])
    }

    @Test func hiddenCalendarsProtectLocalDatesWithoutLeakingOrdinaryCells() throws {
        let db = try AppDatabase.inMemory()
        var calendar = Fixtures.utc
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var informational = holiday("birthday")
        informational.autoBlocksDay = false
        var optedOut = holiday("opted-out")
        optedOut.blocksDay = false
        let hidden = Fixtures.calendar(selected: false)
        try db.apply(SyncResponse(cursor: "c", events: [holiday(), informational, optedOut], calendars: [hidden]))
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        for offset in [0, 1] {
            let day = DateNavigation.shift(first, by: offset, calendar: calendar)
            let agenda = try db.agenda(for: day, calendar: calendar)
            #expect(agenda.events.isEmpty)
            #expect(agenda.blockingAllDayEvents.map(\.id) == ["holiday"])
            #expect(agenda.blockingAllDayEvents.first?.blockingReason == "US public holiday.")
        }
        #expect(try db.agenda(for: DateNavigation.shift(first, by: -1, calendar: calendar), calendar: calendar).blockingAllDayEvents.isEmpty)
        #expect(try db.agenda(for: DateNavigation.shift(first, by: 2, calendar: calendar), calendar: calendar).blockingAllDayEvents.isEmpty)
        try db.setCalendarBlocksScheduling(id: hidden.id, blocksScheduling: false)
        #expect(try db.agenda(for: first, calendar: calendar).blockingAllDayEvents.isEmpty)
    }

    @Test func protectedDayObservationTracksJudgmentsOverridesAndCalendarGate() async throws {
        let db = try AppDatabase.inMemory()
        var event = holiday()
        event.autoBlocksDay = false
        try db.apply(SyncResponse(cursor: "c", events: [event], calendars: [Fixtures.calendar(selected: false)]))
        let range = Fixtures.instant("2026-11-01T00:00:00Z")..<Fixtures.instant("2026-11-02T00:00:00Z")
        var observation = db.observeBlockingAllDayEvents(in: range, calendar: Fixtures.utc).makeAsyncIterator()
        #expect(try await observation.next() == [])
        event.autoBlocksDay = true
        try db.apply(SyncResponse(cursor: "c2", events: [event], calendars: [Fixtures.calendar(selected: false)]))
        #expect(try await observation.next()?.map(\.id) == [event.id])
        try db.setEventBlocksDay(id: event.id, blocksDay: false)
        #expect(try await observation.next() == [])
        try db.setEventBlocksDay(id: event.id, blocksDay: nil)
        #expect(try await observation.next()?.map(\.id) == [event.id])
        try db.setCalendarBlocksScheduling(id: "cal", blocksScheduling: false)
        #expect(try await observation.next() == [])
    }

    @Test func judgmentsAndDisplayNamesRoundTripAndStaleEditorsKeepServerMetadata() throws {
        let db = try AppDatabase.inMemory()
        var stale = holiday()
        stale.autoBlocksDay = false
        stale.blockingReason = "Old reason."
        var current = holiday()
        current.blocksDay = false
        var account = Fixtures.account()
        account.displayName = "Swaraj Banerjee"
        try db.apply(SyncResponse(cursor: "c", events: [current], accounts: [account], calendars: [Fixtures.calendar()]))
        #expect(try db.event(id: current.id) == current)
        #expect(try db.accounts() == [account])
        stale.summary = "A renamed holiday"
        try db.saveEvent(stale)
        let stored = try #require(try db.event(id: current.id))
        #expect(stored.blocksDay == false && stored.autoBlocksDay == true)
        #expect(stored.blockingReason == "US public holiday.")
        let pending = try #require(try db.pendingWrites().first)
        let data = try #require(pending.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["blocksDay"] as? Bool == false)
        #expect(body["autoBlocksDay"] == nil && body["blockingReason"] == nil)
        current.blocksDay = nil
        try db.apply(SyncResponse(cursor: "c2", events: [current], calendars: [Fixtures.calendar()]))
        #expect(try db.event(id: current.id)?.blocksDay == false)
    }

    @Test func openRowObservationFollowsHiddenInformationalEventsAfterProtectionIsRemoved() async throws {
        let db = try AppDatabase.inMemory()
        var event = holiday()
        event.autoBlocksDay = false
        event.blocksDay = true
        try db.apply(SyncResponse(cursor: "c", events: [event], calendars: [Fixtures.calendar(selected: false)]))
        var rows = db.observeEvent(id: event.id).makeAsyncIterator()
        let initial = try #require(try await rows.next())
        #expect(initial?.blocksDay == true)
        try db.setEventBlocksDay(id: event.id, blocksDay: false)
        let optedOut = try #require(try await rows.next())
        #expect(optedOut?.blocksDay == false)
        #expect(try db.events(in: Fixtures.allTime).isEmpty)
        #expect(try db.blockingAllDayEvents(in: Fixtures.allTime).isEmpty)
        try db.setEventBlocksDay(id: event.id, blocksDay: nil)
        let automatic = try #require(try await rows.next())
        #expect(automatic?.blocksDay == nil)
        #expect(automatic?.autoBlocksDay == false)
        #expect(try db.events(in: Fixtures.allTime).isEmpty)
        #expect(try db.blockingAllDayEvents(in: Fixtures.allTime).isEmpty)
        try db.setEventBlocksDay(id: event.id, blocksDay: true)
        let forced = try #require(try await rows.next())
        #expect(forced?.blocksDay == true)
    }
}
