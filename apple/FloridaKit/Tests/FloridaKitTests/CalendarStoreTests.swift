import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct CalendarStoreTests {
    @Test func existingStoresKeepVisibilityAndDefaultToBlocking() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v6")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO calendar (id, accountId, googleId, summary, accessRole, selected, updatedAt)
                VALUES ('visible', 'acct', 'g-visible', 'Visible', 'owner', 1, '2026-11-08 00:00:00.000'),
                       ('hidden', 'acct', 'g-hidden', 'Hidden', 'reader', 0, '2026-11-08 00:00:00.000');
                INSERT INTO syncState (key, value) VALUES ('cursor', 'existing-cursor');
                """)
        }
        let db = try AppDatabase(writer: queue)
        let calendars = try db.calendars()
        #expect(calendars.map(\.id) == ["hidden", "visible"])
        #expect(calendars.map(\.selected) == [false, true])
        #expect(calendars.allSatisfy { $0.blocksScheduling })
        #expect(calendars.allSatisfy { $0.updatedAt == Fixtures.t0 })
        #expect(try db.cursor() == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func syncRoundTripsIndependentFlags(selected: Bool, blocksScheduling: Bool) throws {
        let db = try AppDatabase.inMemory()
        var calendar = Fixtures.calendar(selected: selected)
        calendar.blocksScheduling = blocksScheduling
        try db.apply(SyncResponse(cursor: "c1", calendars: [calendar]))
        #expect(try db.calendars() == [calendar])
        calendar.blocksScheduling.toggle()
        try db.apply(SyncResponse(cursor: "c2", calendars: [calendar]))
        #expect(try db.calendars() == [calendar])
    }

    @Test func localBlockingEditsAreObservedWithoutChangingVisibility() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(
            cursor: "c1",
            events: [Fixtures.event(id: "meeting", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")],
            calendars: [Fixtures.calendar()]))
        var calendars = db.observeCalendars().makeAsyncIterator()
        #expect(try await calendars.next()?.first?.blocksScheduling == true)

        let now = Fixtures.instant("2026-11-09T12:00:00Z")
        try db.setCalendarBlocksScheduling(id: "cal", blocksScheduling: false, now: now)
        let changed = try #require(try await calendars.next()?.first)
        #expect(changed.blocksScheduling == false)
        #expect(changed.selected)
        #expect(changed.updatedAt == now)
        #expect(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc).map(\.id) == ["meeting"])

        try db.setCalendarSelected(id: "cal", selected: false, now: now)
        let hidden = try #require(try await calendars.next()?.first)
        #expect(hidden.selected == false)
        #expect(hidden.blocksScheduling == false)
        #expect(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc).isEmpty)

        try db.setCalendarBlocksScheduling(id: "cal", blocksScheduling: true, now: now)
        let blocking = try #require(try await calendars.next()?.first)
        #expect(blocking.selected == false)
        #expect(blocking.blocksScheduling)
        #expect(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc).isEmpty)
    }
}
