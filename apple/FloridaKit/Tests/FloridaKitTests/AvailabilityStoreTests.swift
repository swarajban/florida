import Foundation
import Testing
@testable import FloridaKit

@Suite struct AvailabilityStoreTests {
    @Test func availabilityUsesBlockingInsteadOfDisplayVisibility() throws {
        let db = try AppDatabase.inMemory()
        var hiddenBusy = Fixtures.calendar(id: "hidden-busy", selected: false)
        hiddenBusy.blocksScheduling = true
        var visibleFree = Fixtures.calendar(id: "visible-free", selected: true)
        visibleFree.blocksScheduling = false
        let visibleBusy = Fixtures.calendar(id: "visible-busy", selected: true)
        var hiddenFree = Fixtures.calendar(id: "hidden-free", selected: false)
        hiddenFree.blocksScheduling = false
        let calendars = [hiddenBusy, visibleFree, visibleBusy, hiddenFree]
        let events = calendars.map { calendar in
            Fixtures.event(
                id: calendar.id, calendarId: calendar.id,
                start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        }
        try db.apply(SyncResponse(cursor: "c1", events: events, calendars: calendars))
        let range = Fixtures.instant("2026-11-09T00:00:00Z")..<Fixtures.instant("2026-11-10T00:00:00Z")
        #expect(Set(try db.events(in: range, calendar: Fixtures.utc).map(\.id)) == ["visible-free", "visible-busy"])
        #expect(Set(try db.availabilityEvents(in: range, calendar: Fixtures.utc).map(\.id)) == ["hidden-busy", "visible-busy"])
    }

    @Test func availabilityQueryMapsAllDayDatesInTheRoutineZone() throws {
        let db = try AppDatabase.inMemory()
        var calendar = Fixtures.utc
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var event = Fixtures.event(id: "day", start: "2026-11-08T00:00:00Z", end: "2026-11-09T00:00:00Z")
        event.allDay = true
        event.eventType = "outOfOffice"
        try db.apply(SyncResponse(cursor: "c1", events: [event], calendars: [Fixtures.calendar(selected: false)]))
        let evening = Fixtures.instant("2026-11-09T03:00:00Z")..<Fixtures.instant("2026-11-09T04:00:00Z")
        let rows = try db.availabilityEvents(in: evening, calendar: calendar)
        #expect(rows.map(\.id) == ["day"])
        var schedule = Fixtures.schedule()
        schedule.timeZone = "UTC"
        schedule.windows = [ScheduleWindow(days: Array(0...6), start: "00:00", end: "24:00")]
        #expect(Availability.freeRanges(
            in: evening, schedules: [schedule], events: [], tasks: [], placements: [],
            commitments: [], now: evening.lowerBound, timeZone: calendar.timeZone)
            == [AvailabilityRange(start: evening.lowerBound, end: evening.upperBound)])
        #expect(Availability.freeRanges(
            in: evening, schedules: [schedule], events: rows, tasks: [], placements: [],
            commitments: [], now: evening.lowerBound, timeZone: calendar.timeZone).isEmpty)
        let following = Fixtures.instant("2026-11-10T03:00:00Z")..<Fixtures.instant("2026-11-10T04:00:00Z")
        #expect(try db.availabilityEvents(in: following, calendar: calendar).isEmpty)
    }

    @Test func availabilityObservationFollowsBlockingAndHiddenEventWrites() async throws {
        let db = try AppDatabase.inMemory()
        let event = Fixtures.event(id: "hidden", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        try db.apply(SyncResponse(cursor: "c1", events: [event], calendars: [Fixtures.calendar(selected: false)]))
        let range = Fixtures.instant("2026-11-09T00:00:00Z")..<Fixtures.instant("2026-11-10T00:00:00Z")
        var iterator = db.observeAvailabilityEvents(in: range, calendar: Fixtures.utc).makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.id) == ["hidden"])
        try db.setCalendarBlocksScheduling(id: "cal", blocksScheduling: false)
        #expect(try await iterator.next() == [])
        try db.setCalendarBlocksScheduling(id: "cal", blocksScheduling: true)
        #expect(try await iterator.next()?.map(\.id) == ["hidden"])
        try db.deleteEvent(id: "hidden", now: Fixtures.t0)
        #expect(try await iterator.next() == [])
    }

    @Test func availabilityQueryExcludesMissingTimesDeletedCancelledAndDeclinedEvents() throws {
        let db = try AppDatabase.inMemory()
        let event = Fixtures.event(id: "live", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        var deleted = event
        deleted.id = "deleted"
        deleted.deletedAt = Fixtures.t0
        var cancelled = event
        cancelled.id = "cancelled"
        cancelled.status = "cancelled"
        var declined = event
        declined.id = "declined"
        declined.responseStatus = "declined"
        var missing = event
        missing.id = "missing"
        missing.endAt = nil
        var outside = event
        outside.id = "outside"
        outside.startAt = Fixtures.instant("2026-12-09T10:00:00Z")
        outside.endAt = Fixtures.instant("2026-12-09T11:00:00Z")
        try db.apply(SyncResponse(
            cursor: "c1", events: [event, deleted, cancelled, declined, missing, outside],
            calendars: [Fixtures.calendar()]))
        let range = Fixtures.instant("2026-11-09T00:00:00Z")..<Fixtures.instant("2026-11-10T00:00:00Z")
        #expect(try db.availabilityEvents(in: range, calendar: Fixtures.utc).map(\.id) == ["live"])
    }
}
