import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct EventMoveWriteTests {
    private func event() -> CalendarEvent {
        Fixtures.event(id: "event", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z")
    }

    @Test(arguments: [false, true])
    func moveUsesLiveTimesAndUndoPreservesUnrelatedChanges(_ series: Bool) throws {
        let db = try AppDatabase.inMemory()
        var live = event()
        live.startAt = Fixtures.instant("2026-11-09T19:00:00Z")
        live.endAt = Fixtures.instant("2026-11-09T21:00:00Z")
        live.recurringEventId = series ? "series" : nil
        try db.apply(SyncResponse(cursor: "live", events: [live]))
        let mutation = try db.moveEvent(id: live.id, toStart: Fixtures.t0, series: series, now: Fixtures.t0)
        #expect(mutation.from == DateInterval(start: live.startAt!, end: live.endAt!))
        #expect(mutation.to.duration == 7_200)
        let pending = try #require(try db.pendingWrites().first?.seq)
        try db.removePendingWrite(seq: pending)
        var accepted = try #require(try db.event(id: live.id))
        accepted.location = "Remote room"
        accepted.description = "Remote notes"
        try db.apply(SyncResponse(cursor: "accepted", events: [accepted]))
        #expect(try db.undoEventMove(id: live.id, expected: mutation.to, restoring: mutation.from, series: series, now: Fixtures.t0))
        let restored = try #require(try db.event(id: live.id))
        #expect(restored.startAt == live.startAt && restored.endAt == live.endAt)
        #expect(restored.location == "Remote room" && restored.description == "Remote notes")
    }

    @Test(arguments: [false, true])
    func undoRefusesChangedOrDeletedLiveRows(_ deleted: Bool) throws {
        let db = try AppDatabase.inMemory()
        var live = event()
        let expected = DateInterval(start: live.startAt!, end: live.endAt!)
        if deleted { live.deletedAt = Fixtures.t0 }
        else { live.startAt = live.startAt?.addingTimeInterval(3_600) }
        try db.apply(SyncResponse(cursor: "changed", events: [live]))
        let restoring = DateInterval(start: Fixtures.t0, duration: 3_600)
        #expect(try !db.undoEventMove(id: live.id, expected: expected, restoring: restoring))
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.event(id: live.id) == (deleted ? nil : live))
    }
}
