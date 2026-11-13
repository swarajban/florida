import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct SeriesUndoIntegrationTests {
    private func fixture() throws -> (AppDatabase, CalendarEvent, CalendarEvent) {
        let db = try AppDatabase.inMemory()
        var anchor = Fixtures.event(id: "anchor", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        anchor.recurringEventId = "series"
        var sibling = Fixtures.event(id: "sibling", start: "2026-11-10T10:00:00Z", end: "2026-11-10T11:00:00Z")
        sibling.recurringEventId = "series"
        try db.apply(SyncResponse(cursor: "initial", events: [anchor, sibling]))
        return (db, anchor, sibling)
    }

    private func undo(_ mutation: AppDatabase.EventMutation, in db: AppDatabase, series: Bool) throws -> Bool {
        try db.undoEventMove(id: "anchor", expected: mutation.to, restoring: mutation.from,
            series: series, expectedSeries: mutation.expectedSeries)
    }

    @Test func cancellingSeriesMoveCannotBeUndoneAfterAnchorReturnsToExpectedTime() throws {
        let (db, anchor, sibling) = try fixture()
        let series = try db.moveEvent(id: anchor.id, toStart: anchor.startAt!.addingTimeInterval(3_600), series: true)
        let single = try db.moveEvent(id: anchor.id, toStart: anchor.startAt!.addingTimeInterval(7_200))
        #expect(try db.event(id: sibling.id)?.startAt == sibling.startAt)
        #expect(try undo(single, in: db, series: false))
        #expect(try db.event(id: anchor.id)?.startAt == series.to.start)
        let pending = try db.pendingWrites()
        #expect(try !undo(series, in: db, series: true))
        #expect(try db.event(id: anchor.id)?.startAt == series.to.start)
        #expect(try db.event(id: sibling.id)?.startAt == sibling.startAt)
        #expect(try db.pendingWrites().map(\.body) == pending.map(\.body))
    }

    @Test func stackedSeriesMovesUndoInOrder() throws {
        let (db, anchor, sibling) = try fixture()
        let first = try db.moveEvent(id: anchor.id, toStart: anchor.startAt!.addingTimeInterval(3_600), series: true)
        let second = try db.moveEvent(id: anchor.id, toStart: anchor.startAt!.addingTimeInterval(7_200), series: true)
        #expect(try undo(second, in: db, series: true))
        #expect(try db.event(id: sibling.id)?.startAt == sibling.startAt?.addingTimeInterval(3_600))
        #expect(try undo(first, in: db, series: true))
        #expect(try db.event(id: anchor.id)?.startAt == anchor.startAt)
        #expect(try db.event(id: sibling.id)?.startAt == sibling.startAt)
    }

    @Test func acceptedSeriesMoveUndoPreservesUnrelatedText() throws {
        let (db, anchor, sibling) = try fixture()
        let move = try db.moveEvent(id: anchor.id, toStart: anchor.startAt!.addingTimeInterval(3_600), series: true)
        let pending = try #require(try db.pendingWrites().first)
        let accepted = try #require(try db.event(id: anchor.id))
        try db.completePendingWrite(pending, record: accepted, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
        try db.writer.write { db in
            try db.execute(sql: "UPDATE event SET location = 'Remote room', description = 'Remote notes'")
        }
        #expect(try undo(move, in: db, series: true))
        for original in [anchor, sibling] {
            let restored = try #require(try db.event(id: original.id))
            #expect(restored.startAt == original.startAt && restored.endAt == original.endAt)
            #expect(restored.location == "Remote room" && restored.description == "Remote notes")
        }
    }

    @Test(arguments: ["changed", "missing", "membership", "added"])
    func seriesUndoRefusesChangedSiblingState(_ change: String) throws {
        let (db, anchor, sibling) = try fixture()
        let move = try db.moveEvent(id: anchor.id, toStart: anchor.startAt!.addingTimeInterval(3_600), series: true)
        try db.writer.write { db in
            switch change {
            case "changed":
                try db.execute(sql: "UPDATE event SET startAt = ?, endAt = ? WHERE id = ?",
                    arguments: [sibling.startAt!.addingTimeInterval(9_000), sibling.endAt!.addingTimeInterval(9_000), sibling.id])
            case "missing":
                try CalendarEvent.deleteOne(db, key: sibling.id)
            case "membership":
                try db.execute(sql: "UPDATE event SET recurringEventId = 'other-series' WHERE id = ?", arguments: [sibling.id])
            default:
                var added = sibling
                added.id = "added"
                try added.save(db)
            }
        }
        let before = try db.writer.read { try CalendarEvent.fetchAll($0).sorted { $0.id < $1.id } }
        let pending = try db.pendingWrites()
        #expect(try !undo(move, in: db, series: true))
        #expect(try db.writer.read { try CalendarEvent.fetchAll($0).sorted { $0.id < $1.id } } == before)
        #expect(try db.pendingWrites().map(\.body) == pending.map(\.body))
    }

    @Test func legacySeriesUndoCannotShiftKnownSiblings() throws {
        let (db, anchor, sibling) = try fixture()
        let move = try db.moveEvent(id: anchor.id, toStart: anchor.startAt!.addingTimeInterval(3_600), series: true)
        #expect(try !db.undoEventMove(id: anchor.id, expected: move.to, restoring: move.from, series: true))
        #expect(try db.event(id: sibling.id)?.startAt == sibling.startAt?.addingTimeInterval(3_600))
    }
}
