import Foundation
import Testing
@testable import FloridaKit

struct CalendarActivationTests {
    @Test func boundedBackoffAndTimeout() {
        var state = CalendarActivationState(entries: ["a": .init(started: 100)])
        let early = state.tick(now: 101)
        #expect(!early)
        for offset in CalendarActivationState.pullOffsets {
            let due = state.tick(now: 100 + offset)
            let duplicate = state.tick(now: 100 + offset)
            #expect(due)
            #expect(!duplicate)
        }
        let expired = state.tick(now: 120)
        #expect(!expired)
        #expect(state.entries.isEmpty)
    }

    @Test func settlesOnSyncStampOrDeselection() {
        let old = Date(timeIntervalSince1970: 1)
        var calendar = CalendarInfo(id: "a", accountId: "account", googleId: "a", summary: "Kyle", accessRole: "reader", selected: true, updatedAt: old)
        var state = CalendarActivationState(entries: ["a": .init(started: 0)])
        state.reconcile([calendar])
        #expect(state.entries.count == 1)
        calendar.lastSyncedAt = old
        state.reconcile([calendar])
        #expect(state.entries.isEmpty)
        state.entries["a"] = .init(started: 0)
        state.reconcile([calendar])
        #expect(state.entries.isEmpty)
        state.entries["a"] = .init(started: 0)
        calendar.selected = false
        state.reconcile([calendar])
        #expect(state.entries.isEmpty)
    }

    @Test func syncStampSurvivesWireAndStore() throws {
        let db = try AppDatabase.inMemory()
        let date = Date(timeIntervalSince1970: 100)
        let calendar = CalendarInfo(id: "a", accountId: "account", googleId: "a", summary: "Kyle",
                                    accessRole: "reader", selected: true, lastSyncedAt: date, updatedAt: date)
        let decoded = try JSONCoding.decoder.decode(CalendarInfo.self, from: JSONCoding.encoder.encode(calendar))
        try db.apply(SyncResponse(cursor: date.ISO8601Format(), calendars: [decoded]))
        #expect(try db.calendars().first?.lastSyncedAt == date)
    }

    @MainActor @Test func multipleActivationsAndImmediateCancellation() {
        let activation = CalendarActivation()
        let a = Fixtures.calendar()
        var b = a
        b.id = "b"
        activation.setSelected(true, calendar: a, requestSync: {})
        #expect(activation.status(in: [a]) == "Syncing \(a.summary)…")
        activation.setSelected(true, calendar: b, requestSync: {})
        #expect(activation.status(in: [a, b]) == "Syncing 2 calendars…")
        activation.setSelected(false, calendar: a, requestSync: {})
        #expect(activation.syncingCalendarIds == ["b"])
        activation.setSelected(false, calendar: b, requestSync: {})
        #expect(activation.status(in: [a, b]) == nil)
    }
}
