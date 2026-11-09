import Foundation
import Testing
@testable import FloridaKit

@Suite struct AppDatabaseObservationTests {
    @Test func openTasksObservationYieldsNowAndAfterWrites() async throws {
        let db = try AppDatabase.inMemory()
        var iterator = db.observeOpenTasks().makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial == [])

        try db.saveTask(Fixtures.task(id: "t1"), now: Fixtures.t0)
        let afterInsert = try await iterator.next()
        #expect(afterInsert?.map(\.id) == ["t1"])

        try db.completeTask(id: "t1", at: Fixtures.instant("2026-11-08T12:00:00Z"))
        let afterComplete = try await iterator.next()
        #expect(afterComplete == [])
    }

    @Test func eventsObservationIsScopedToTheRangeAndSelectedCalendars() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(
            cursor: "c1",
            events: [
                Fixtures.event(id: "inside", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z"),
                Fixtures.event(id: "outside", start: "2026-12-09T10:00:00Z", end: "2026-12-09T11:00:00Z"),
            ],
            calendars: [Fixtures.calendar(id: "cal", selected: true)]))
        let range = Fixtures.instant("2026-11-09T00:00:00Z")..<Fixtures.instant("2026-11-10T00:00:00Z")
        var iterator = db.observeEvents(in: range).makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial?.map(\.id) == ["inside"])

        try db.setCalendarSelected(id: "cal", selected: false)
        let afterDeselect = try await iterator.next()
        #expect(afterDeselect == [])
    }

    @Test func eventsObservationFollowsLocalEventWrites() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c1", calendars: [Fixtures.calendar()]))
        let range = Fixtures.instant("2026-11-09T00:00:00Z")..<Fixtures.instant("2026-11-10T00:00:00Z")
        var iterator = db.observeEvents(in: range, calendar: Fixtures.utc).makeAsyncIterator()
        #expect(try await iterator.next() == [])

        // A brand-new event, not yet known to the server, appears at once.
        var event = Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        event.googleId = ""
        try db.saveEvent(event, now: Fixtures.t0)
        #expect(try await iterator.next()?.map(\.id) == ["e1"])

        // And a locally deleted one disappears at once, before any push.
        try db.deleteEvent(id: "e1", now: Fixtures.t0)
        #expect(try await iterator.next() == [])
    }

    @Test func agendaObservationFollowsPlacementsAndTaskEdits() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c1", tasks: [Fixtures.task(id: "t1", title: "Write report")]))
        var iterator = db.observeAgenda(for: Fixtures.instant("2026-11-09T13:37:00Z"), calendar: Fixtures.utc)
            .makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial?.day == Fixtures.instant("2026-11-09T00:00:00Z"))
        #expect(initial?.placements == [])

        // Only the block on the observed day shows up.
        try db.apply(SchedulingResult(placements: [
            Fixtures.piece(taskId: "t1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z"),
            Fixtures.piece(taskId: "t1", start: "2026-11-10T09:00:00Z", end: "2026-11-10T10:00:00Z"),
        ]), computedAt: Fixtures.t0)
        let scheduled = try await iterator.next()
        #expect(scheduled?.placements.map(\.placement.startAt) == [Fixtures.instant("2026-11-09T17:00:00Z")])
        #expect(scheduled?.placements.map(\.task.title) == ["Write report"])

        // Editing the task re-yields because the joined task row changed.
        try db.saveTask(Fixtures.task(id: "t1", title: "Send report"), now: Fixtures.t0)
        let renamed = try await iterator.next()
        #expect(renamed?.placements.map(\.task.title) == ["Send report"])
    }

    @Test func placementsCategoriesAndPendingCountObserveTheirTables() async throws {
        let db = try AppDatabase.inMemory()
        var placements = db.observePlacements().makeAsyncIterator()
        var categories = db.observeCategories().makeAsyncIterator()
        var pending = db.observePendingWriteCount().makeAsyncIterator()
        #expect(try await placements.next() == [])
        #expect(try await categories.next() == [])
        #expect(try await pending.next() == 0)

        try db.saveCategory(Fixtures.category(id: "p1"), now: Fixtures.t0)
        #expect(try await categories.next()?.map(\.id) == ["p1"])
        #expect(try await pending.next() == 1)

        try db.apply(SchedulingResult(placements: [
            Fixtures.piece(taskId: "t1", start: "2026-11-09T18:00:00Z", end: "2026-11-09T19:00:00Z"),
            Fixtures.piece(taskId: "t2", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z"),
        ]), computedAt: Fixtures.t0)
        #expect(try await placements.next()?.map(\.taskId) == ["t2", "t1"])
    }

    @Test func schedulesAndUnscheduledObserveTheirTables() async throws {
        let db = try AppDatabase.inMemory()
        var schedules = db.observeSchedules().makeAsyncIterator()
        var unscheduled = db.observeUnscheduled().makeAsyncIterator()
        #expect(try await schedules.next() == [])
        #expect(try await unscheduled.next() == [])

        // Oldest first, regardless of name; deleted ones are hidden.
        var newer = Fixtures.schedule(id: "a-newer")
        newer.createdAt = Fixtures.instant("2026-11-09T00:00:00Z")
        try db.apply(SyncResponse(cursor: "c1", schedules: [newer, Fixtures.schedule(id: "z-older")]))
        #expect(try await schedules.next()?.map(\.id) == ["z-older", "a-newer"])
        try db.deleteSchedule(id: "z-older", now: Fixtures.t0)
        #expect(try await schedules.next()?.map(\.id) == ["a-newer"])

        try db.apply(SchedulingResult(unscheduled: [.init(taskId: "t1", reason: "no_fit_in_horizon", unplacedMinutes: 20)]), computedAt: Fixtures.t0)
        #expect(try await unscheduled.next()?.map(\.taskId) == ["t1"])
    }

    @Test func accountsAndCalendarsObservationsFollowSyncResponses() async throws {
        let db = try AppDatabase.inMemory()
        var accounts = db.observeAccounts().makeAsyncIterator()
        var calendars = db.observeCalendars().makeAsyncIterator()
        #expect(try await accounts.next() == [])
        #expect(try await calendars.next() == [])

        try db.apply(SyncResponse(
            cursor: "c1", accounts: [Fixtures.account()],
            calendars: [Fixtures.calendar(id: "b"), Fixtures.calendar(id: "a")]))
        #expect(try await accounts.next()?.map(\.id) == ["acct"])
        #expect(try await calendars.next()?.map(\.id) == ["a", "b"])
    }
}
