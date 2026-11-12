import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import FloridaKit

@Suite struct EventDayBlockingTests {
    let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test-token")

    func event(_ id: String = "e1") -> CalendarEvent {
        var event = Fixtures.event(id: id, start: "2026-11-09T00:00:00Z", end: "2026-11-10T00:00:00Z", allDay: true)
        event.recurringEventId = "series"
        return event
    }

    @Test func upgradeDefaultsToAutomaticAndFetchesExistingOverrides() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v7-calendar-blocking")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO event (id, calendarId, googleId, status, summary, startAt, endAt, allDay, updatedAt)
                VALUES ('e1', 'cal', 'g-e1', 'confirmed', 'Holiday', '2026-11-09 00:00:00.000',
                        '2026-11-10 00:00:00.000', 1, '2026-11-08 00:00:00.000');
                INSERT INTO syncState (key, value) VALUES ('cursor', 'old');
                """)
        }
        let db = try AppDatabase(writer: queue)
        #expect(try db.event(id: "e1")?.blocksDay == nil)
        #expect(try db.event(id: "e1")?.summary == "Holiday")
        #expect(try db.cursor() == nil)
    }

    @Test(arguments: [nil, true, false] as [Bool?])
    func hiddenReadOnlyOccurrenceUpdatesLocallyAndQueuesOnlyTheOverride(blocksDay: Bool?) async throws {
        let db = try AppDatabase.inMemory()
        var calendar = Fixtures.calendar(selected: false)
        calendar.accessRole = "reader"
        try db.apply(SyncResponse(cursor: "c", events: [event(), event("e2")], calendars: [calendar]))
        var observation = db.observe { try CalendarEvent.fetchOne($0, key: "e1") }.makeAsyncIterator()
        _ = try await observation.next()
        let now = Fixtures.instant("2026-11-09T12:00:00Z")
        try db.setEventBlocksDay(id: "e1", blocksDay: blocksDay, now: now)
        #expect(try db.event(id: "e1")?.blocksDay == blocksDay)
        #expect(try db.event(id: "e1")?.updatedAt == now)
        let observed = try #require(try await observation.next())
        #expect(observed?.updatedAt == now)
        #expect(try db.event(id: "e2")?.blocksDay == nil)
        let pending = try #require(try db.pendingWrites().first)
        #expect(pending.entity == .event && pending.op == .patch && pending.entityId == "e1")
        let data = try #require(pending.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["blocksDay"])
        if let blocksDay {
            #expect(body["blocksDay"] as? Bool == blocksDay)
        } else {
            #expect(body["blocksDay"] is NSNull)
        }
    }

    @Test func resetsCoalesceAndSurvivePulls() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c1", events: [event()], calendars: [Fixtures.calendar()]))
        try db.setEventBlocksDay(id: "e1", blocksDay: true)
        try db.setEventBlocksDay(id: "e1", blocksDay: false)
        try db.setEventBlocksDay(id: "e1", blocksDay: nil)
        var remote = event()
        remote.blocksDay = true
        try db.apply(SyncResponse(cursor: "c2", events: [remote], calendars: [Fixtures.calendar()]))
        #expect(try db.event(id: "e1")?.blocksDay == nil)
        let queue = try db.pendingWrites()
        #expect(queue.count == 1)
        #expect(queue.first?.op == .patch)
        let data = try #require(queue.first?.body)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["blocksDay"] is NSNull)
    }

    @Test(arguments: [nil, true, false] as [Bool?])
    func toggleMergesIntoCreationAndLaterStaleEditorKeepsIt(blocksDay: Bool?) throws {
        let db = try AppDatabase.inMemory()
        var draft = event()
        draft.googleId = ""
        let recurrence = EventRecurrence(frequency: .weekly, timeZone: "America/Los_Angeles")
        try db.saveEvent(draft, recurrence: recurrence)
        try db.setEventBlocksDay(id: draft.id, blocksDay: blocksDay)
        draft.summary = "Edited after choosing blocking"
        try db.saveEvent(draft)
        let queue = try db.pendingWrites()
        #expect(queue.count == 1)
        #expect(queue.first?.op == .put)
        let write = try JSONCoding.decoder.decode(EventWrite.self, from: try #require(queue.first?.body))
        #expect(write.blocksDay == blocksDay)
        #expect(write.recurrence == recurrence)
        #expect(write.summary == draft.summary)
        #expect(try db.event(id: draft.id)?.blocksDay == blocksDay)
    }

    @Test func laterNormalSaveKeepsTheQueuedResetAndExistingScope() throws {
        let db = try AppDatabase.inMemory()
        var original = event()
        original.blocksDay = true
        try db.apply(SyncResponse(cursor: "c", events: [original]))
        try db.setEventBlocksDay(id: original.id, blocksDay: nil)
        original.summary = "A stale editor snapshot"
        try db.saveEvent(original)
        var write = try JSONCoding.decoder.decode(EventWrite.self, from: try #require(try db.pendingWrites().first?.body))
        #expect(write.blocksDay == nil)
        #expect(try db.event(id: original.id)?.blocksDay == nil)
        write.scope = .series
        try db.requeue(PendingWrite(entity: .event, entityId: "other", op: .put,
            body: JSONCoding.encoder.encode(write), createdAt: Fixtures.t0))
        var other = event("other")
        other.blocksDay = false
        try db.writer.write { try other.save($0) }
        try db.setEventBlocksDay(id: "other", blocksDay: true)
        let pending = try #require(try db.pendingWrites().first { $0.entityId == "other" })
        let merged = try JSONCoding.decoder.decode(EventWrite.self, from: try #require(pending.body))
        #expect(merged.blocksDay == true)
        #expect(merged.scope == .series)
    }

    @Test func timedAndDeletedEventsDoNotQueueBlockingChanges() throws {
        let db = try AppDatabase.inMemory()
        var timed = event()
        timed.allDay = false
        try db.apply(SyncResponse(cursor: "c", events: [timed]))
        #expect(throws: AppDatabase.WriteError.eventNotAllDay(id: timed.id)) {
            try db.setEventBlocksDay(id: timed.id, blocksDay: true)
        }
        #expect(try db.pendingWrites().isEmpty)
        timed.allDay = true
        try db.apply(SyncResponse(cursor: "c2", events: [timed]))
        try db.deleteEvent(id: timed.id)
        try db.setEventBlocksDay(id: timed.id, blocksDay: true)
        #expect(try db.pendingWrites().map(\.op) == [.delete])
    }

    @Test(arguments: [nil, true, false] as [Bool?])
    func clientPushesTheIsolatedPatchAndAppliesItsReply(blocksDay: Bool?) async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", events: [event()], calendars: [Fixtures.calendar()]))
        try db.setEventBlocksDay(id: "e1", blocksDay: blocksDay)
        var accepted = event()
        accepted.blocksDay = blocksDay
        let transport = FakeTransport([try .ok(Fixtures.putResponse("event", accepted))])
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 1)
        let request = try #require(transport.requests.first)
        #expect(request.method == "PATCH" && request.path == "/api/events/e1")
        let data = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["blocksDay"])
        if let blocksDay {
            #expect(body["blocksDay"] as? Bool == blocksDay)
        } else {
            #expect(body["blocksDay"] is NSNull)
        }
        #expect(try db.event(id: "e1") == accepted)
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func failedPushKeepsTheOverrideAcrossTheFollowingPull() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", events: [event()]))
        try db.setEventBlocksDay(id: "e1", blocksDay: true)
        let transport = FakeTransport([.failure(NetworkDown()), try .ok(SyncResponse(cursor: "c2", events: [event()]))])
        let client = SyncClient(database: db, config: config, transport: transport)
        await #expect(throws: SyncError.self) { try await client.sync() }
        #expect(try db.event(id: "e1")?.blocksDay == true)
        #expect(try db.pendingWrites().map(\.op) == [.patch])
    }

    @Test func olderAcceptedPatchCannotOverwriteANewerReset() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", events: [event()]))
        try db.setEventBlocksDay(id: "e1", blocksDay: true)
        var accepted = event()
        accepted.blocksDay = true
        final class ResetDuringPush: HTTPTransport, @unchecked Sendable {
            let database: AppDatabase
            let body: Data
            init(database: AppDatabase, body: Data) { self.database = database; self.body = body }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                try database.setEventBlocksDay(id: "e1", blocksDay: nil)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let transport = ResetDuringPush(database: db, body: try Fixtures.putResponse("event", accepted))
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 1)
        #expect(try db.event(id: "e1")?.blocksDay == nil)
        #expect(try db.pendingWrites().map(\.op) == [.patch])
    }
}
