import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloridaKit

@Suite struct SyncClientTests {
    let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "secret-token")

    func client(_ db: AppDatabase, _ transport: FakeTransport) -> SyncClient {
        SyncClient(database: db, config: config, transport: transport)
    }

    // MARK: 5. Happy path

    @Test func syncPushesInOrderThenPulls() async throws {
        let db = try AppDatabase.inMemory()
        // A prior pull left a cursor behind; the next pull must send it back as `since`.
        try db.apply(SyncResponse(cursor: "2026-11-08T09:00:00.000Z", categories: [Fixtures.category()]))

        var t1 = Fixtures.task(id: "t1", title: "first")
        try db.saveTask(t1, now: Fixtures.instant("2026-11-08T10:00:00Z"))
        try db.saveCategory(Fixtures.category(id: "p2", sortOrder: 2), now: Fixtures.instant("2026-11-08T10:01:00Z"))
        try db.deleteTask(id: "t-gone", now: Fixtures.instant("2026-11-08T10:02:00Z"))
        let pending = try db.pendingWrites()
        #expect(pending.count == 3)
        let storedTaskBody = try #require(pending[0].body)

        // Server echoes t1 with normalized fields and a new placement table.
        t1.updatedAt = Fixtures.instant("2026-11-08T10:00:00.123Z")
        t1.notes = "server normalized"
        let afterT1 = SchedulingResult(placements: [Fixtures.piece(taskId: "t1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z")])
        let serverCategory = Fixtures.category(id: "p2", sortOrder: 2)
        let afterDelete = SchedulingResult(placements: [Fixtures.piece(taskId: "t1", start: "2026-11-09T18:00:00Z", end: "2026-11-09T19:00:00Z")])
        let pulled = SyncResponse(
            cursor: "2026-11-08T10:05:00.000Z",
            tasks: [Fixtures.task(id: "from-server")],
            placements: [Fixtures.placement(id: "srv", taskId: "t1", start: "2026-11-09T20:00:00Z", end: "2026-11-09T21:00:00Z")])

        let transport = FakeTransport([
            // The category was saved after the task and still goes first: a task may name it.
            .ok(try Fixtures.putResponse("category", serverCategory)),
            .ok(try Fixtures.putResponse("task", t1, scheduling: afterT1)),
            .ok(try Fixtures.deleteResponse(scheduling: afterDelete)),
            try .ok(pulled),
        ])

        let pushed = try await client(db, transport).sync()
        #expect(pushed == 3)

        let requests = transport.requests
        try #require(requests.count == 4)

        #expect(requests[1].method == "PUT")
        #expect(requests[1].path == "/api/tasks/t1")
        #expect(requests[1].headers["Authorization"] == "Bearer secret-token")
        #expect(requests[1].headers["Content-Type"] == "application/json")
        #expect(requests[1].body == storedTaskBody)
        let sentWrite = try JSONCoding.decoder.decode(TaskWrite.self, from: try #require(requests[1].body))
        #expect(sentWrite.title == "first")

        #expect(requests[0].method == "PUT")
        #expect(requests[0].path == "/api/categories/p2")
        #expect(requests[0].headers["Authorization"] == "Bearer secret-token")
        let sentCategory = try JSONCoding.decoder.decode(CategoryWrite.self, from: try #require(requests[0].body))
        #expect(sentCategory.sortOrder == 2)

        #expect(requests[2].method == "DELETE")
        #expect(requests[2].path == "/api/tasks/t-gone")
        #expect(requests[2].body == nil)
        #expect(requests[2].headers["Authorization"] == "Bearer secret-token")

        #expect(requests[3].method == "GET")
        #expect(requests[3].path == "/api/sync")
        #expect(requests[3].query == ["since": "2026-11-08T09:00:00.000Z"])
        #expect(requests[3].headers["Authorization"] == "Bearer secret-token")

        // Server's copy of t1 won; pending queue drained; pull applied.
        let localT1 = try #require(try db.task(id: "t1"))
        #expect(localT1.notes == "server normalized")
        #expect(localT1.updatedAt == Fixtures.instant("2026-11-08T10:00:00.123Z"))
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.task(id: "from-server") != nil)
        #expect(try db.cursor() == "2026-11-08T10:05:00.000Z")
        // The pull's placements are the final table (they replaced the ones from the PUT/DELETE responses).
        #expect(try db.placements(in: Fixtures.allTime).map(\.id) == ["srv"])
    }

    @Test func pushAppliesReturnedSchedulingPlacements() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveTask(Fixtures.task(id: "t1"), now: Fixtures.t0)
        let scheduling = SchedulingResult(placements: [
            Fixtures.piece(taskId: "t1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z"),
            Fixtures.piece(taskId: "t1", start: "2026-11-10T17:00:00Z", end: "2026-11-10T18:00:00Z"),
        ])
        let transport = FakeTransport([.ok(try Fixtures.putResponse("task", Fixtures.task(id: "t1"), scheduling: scheduling))])

        let pushed = try await client(db, transport).push()
        #expect(pushed == 1)
        let placements = try db.placements(in: Fixtures.allTime)
        #expect(placements.count == 2)
        #expect(placements.map(\.taskId) == ["t1", "t1"])
        #expect(placements.map(\.startAt) == [Fixtures.instant("2026-11-09T17:00:00Z"), Fixtures.instant("2026-11-10T17:00:00Z")])
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func acceptedWriteReplacesUnscheduledFromItsSchedulingResult() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", unscheduled: [
            UnscheduledTask(taskId: "old", reason: "no_fit_in_horizon", unplacedMinutes: 60, computedAt: Fixtures.t0),
        ]))
        try db.saveTask(Fixtures.task(id: "t1"), now: Fixtures.t0)
        let scheduling = SchedulingResult(unscheduled: [.init(taskId: "t1", reason: "no_fit_before_hard_deadline", unplacedMinutes: 25)])
        let transport = FakeTransport([.ok(try Fixtures.putResponse("task", Fixtures.task(id: "t1"), scheduling: scheduling))])

        let before = Date()
        _ = try await client(db, transport).push()
        let rows = try db.unscheduled()
        #expect(rows.map(\.taskId) == ["t1"])
        #expect(rows.first?.unplacedMinutes == 25)
        #expect(rows.first?.reason == "no_fit_before_hard_deadline")
        #expect(rows.allSatisfy { $0.computedAt >= before.addingTimeInterval(-1) })
    }

    @Test func pullWithoutCursorOmitsSince() async throws {
        let db = try AppDatabase.inMemory()
        let transport = FakeTransport([try .ok(SyncResponse(cursor: "first", tasks: [Fixtures.task(id: "t1")]))])
        try await client(db, transport).pull()
        let request = try #require(transport.requests.first)
        #expect(request.path == "/api/sync")
        #expect(request.query.isEmpty)
        #expect(request.query["since"] == nil)
        #expect(try db.cursor() == "first")
        #expect(try db.task(id: "t1") != nil)
    }

    @Test func pushWithEmptyQueueSendsNothing() async throws {
        let db = try AppDatabase.inMemory()
        let transport = FakeTransport([])
        let pushed = try await client(db, transport).push()
        #expect(pushed == 0)
        #expect(transport.requests.isEmpty)
    }

    // MARK: 6. Failure handling

    @Test func fourHundredResetsTheRowToTheServersCopyAndContinues() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveTask(Fixtures.task(id: "bad", categoryId: "gone", title: "local"), now: Fixtures.t0)
        try db.saveTask(Fixtures.task(id: "good"), now: Fixtures.t0)
        let serverCopy = Fixtures.task(id: "bad", title: "server")
        let transport = FakeTransport([
            .error(400, "unknown categoryId gone"),
            try .ok(serverCopy),
            .ok(try Fixtures.putResponse("task", Fixtures.task(id: "good"))),
            try .ok(SyncResponse(cursor: "c")),
        ])

        let client = client(db, transport)
        let pushed = try await client.sync()
        #expect(pushed == 1)
        #expect(transport.requests.map { "\($0.method) \($0.path)" } == [
            "PUT /api/tasks/bad", "GET /api/tasks/bad", "PUT /api/tasks/good", "GET /api/sync",
        ])
        #expect(try db.pendingWrites().isEmpty, "both the rejected and the accepted write leave the queue")

        let rejected = await client.lastRejectedWrites
        #expect(rejected.map(\.write.entityId) == ["bad"])
        #expect(rejected.first?.status == 400)
        #expect(rejected.first?.message == "unknown categoryId gone")

        // The rejected local state is replaced by the server's row, even though the pull's
        // `updatedAt > cursor` diff would never have sent it.
        #expect(try db.task(id: "bad") == serverCopy)
    }

    @Test func fourHundredRemovesRowsTheServerHasTombstonedOrADeleteItNeverHad() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c0", tasks: [Fixtures.task(id: "never"), Fixtures.task(id: "tombstoned")]))
        try db.deleteTask(id: "never", now: Fixtures.t0)
        try db.saveTask(Fixtures.task(id: "tombstoned", title: "local edit"), now: Fixtures.t0)
        let transport = FakeTransport([
            .error(404, "task never not found"),
            .error(404, "task never not found"),
            .error(409, "task is deleted"),
            try .ok(Fixtures.task(id: "tombstoned", deletedAt: Fixtures.instant("2026-11-08T08:00:00Z"))),
            try .ok(SyncResponse(cursor: "c")),
        ])

        let client = client(db, transport)
        #expect(try await client.sync() == 0)
        #expect(transport.requests.map { "\($0.method) \($0.path)" } == [
            "DELETE /api/tasks/never", "GET /api/tasks/never", "PATCH /api/tasks/tombstoned", "GET /api/tasks/tombstoned", "GET /api/sync",
        ])
        // The local tombstone of a row the server never had goes, as does the row the server has tombstoned.
        #expect(try db.task(id: "never") == nil)
        #expect(try db.task(id: "tombstoned") == nil)
        #expect(await client.lastRejectedWrites.map(\.status) == [404, 409])
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func rejectedPutOfARowTheServerNeverHadKeepsTheRow() async throws {
        // Typed offline into a category another device deleted meanwhile: the server refuses the
        // task and has no copy to fall back to. What the user typed must not vanish.
        let db = try AppDatabase.inMemory()
        try db.saveTask(Fixtures.task(id: "new", categoryId: "gone", title: "call dentist"), now: Fixtures.t0)
        let transport = FakeTransport([
            .error(400, "unknown categoryId gone"),
            .error(404, "task new not found"),
            try .ok(SyncResponse(cursor: "c")),
        ])

        let client = client(db, transport)
        #expect(try await client.sync() == 0)
        #expect(transport.requests.map { "\($0.method) \($0.path)" } == ["PUT /api/tasks/new", "GET /api/tasks/new", "GET /api/sync"])
        #expect(try db.task(id: "new")?.title == "call dentist")
        #expect(try db.pendingWrites().isEmpty, "retrying could never succeed")
        let rejected = await client.lastRejectedWrites
        #expect(rejected.map(\.write.entityId) == ["new"])
        #expect(rejected.first?.status == 400)
        #expect(rejected.first?.message == "unknown categoryId gone")

        // Retrying a creation cannot use saveTask's diff: its unchanged local row still exists.
        let original = try #require(rejected.first?.write)
        try db.requeue(original, now: Fixtures.t0)
        let retryTransport = FakeTransport([.ok(try Fixtures.putResponse("task", Fixtures.task(id: "new", title: "call dentist")))])
        #expect(try await self.client(db, retryTransport).push() == 1)
        #expect(retryTransport.requests.first?.method == "PUT")
        #expect(retryTransport.requests.first?.body == original.body)
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func rejectedDeleteOfTheInboxRestoresIt() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c0", categories: [Fixtures.category(id: TaskCategory.inboxId)]))
        try db.deleteCategory(id: TaskCategory.inboxId, now: Fixtures.instant("2026-11-08T10:00:00Z"))
        #expect(try db.categories().isEmpty)

        let transport = FakeTransport([
            .error(400, "the inbox category cannot be deleted"),
            try .ok(Fixtures.category(id: TaskCategory.inboxId)),
            try .ok(SyncResponse(cursor: "c1")),
        ])
        let client = client(db, transport)
        try await client.sync()
        #expect(transport.requests.map { "\($0.method) \($0.path)" } == [
            "DELETE /api/categories/inbox", "GET /api/categories/inbox", "GET /api/sync",
        ])
        #expect(try db.categories().map(\.id) == ["inbox"])
        #expect(await client.lastRejectedWrites.first?.message == "the inbox category cannot be deleted")
    }

    @Test func rejectedWriteStaysQueuedWhenTheRefetchFails() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveSchedule(Fixtures.schedule(id: "s1"), now: Fixtures.t0)
        try db.saveTask(Fixtures.task(id: "later"), now: Fixtures.t0)
        let transport = FakeTransport([
            .error(422, "bad windows"),
            .error(503, "unavailable"),
            try .ok(SyncResponse(cursor: "c", tasks: [Fixtures.task(id: "pulled")])),
        ])

        let client = client(db, transport)
        await #expect(throws: SyncError.self) { try await client.sync() }
        #expect(transport.requests.map { "\($0.method) \($0.path)" } == [
            "PUT /api/schedules/s1", "GET /api/schedules/s1", "GET /api/sync",
        ])
        // Retried next time, when the server can say what the row should be.
        #expect(try db.pendingWrites().map(\.entityId) == ["s1", "later"])
        #expect(try db.task(id: "pulled") != nil)
        #expect(await client.lastRejectedWrites.isEmpty)
    }

    @Test func notFoundWithoutErrorBodyLeavesTheRow() async throws {
        // A server that predates `GET /api/tasks/:id` answers Hono's plain-text 404 for every id;
        // that must not delete the local row.
        let db = try AppDatabase.inMemory()
        try db.saveTask(Fixtures.task(id: "t1", title: "local"), now: Fixtures.t0)
        let transport = FakeTransport([
            .error(400, "validation failed"),
            .json(status: 404, body: Data("404 Not Found".utf8)),
            try .ok(SyncResponse(cursor: "c")),
        ])
        let client = client(db, transport)
        try await client.sync()
        #expect(try db.task(id: "t1")?.title == "local")
        #expect(try db.pendingWrites().isEmpty)
        #expect(await client.lastRejectedWrites.map(\.message) == ["validation failed"])
    }

    // MARK: Discarding queued writes

    @Test func discardDropsTheWriteAndResetsTheRowToTheServersCopy() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c0", tasks: [Fixtures.task(id: "t1", title: "server")]))
        try db.saveTask(Fixtures.task(id: "t1", title: "local edit"), now: Fixtures.t0)
        // Edited elsewhere since, so the server's copy is newer than what this device last pulled.
        let serverCopy = Fixtures.task(id: "t1", title: "edited elsewhere", createdAt: Fixtures.instant("2026-11-08T12:00:00Z"))
        let transport = FakeTransport([try .ok(serverCopy)])

        let client = client(db, transport)
        let write = try #require(try db.pendingWrites().first)
        try await client.discard(write)
        #expect(transport.requests.map { "\($0.method) \($0.path)" } == ["GET /api/tasks/t1"])
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.task(id: "t1") == serverCopy)
    }

    @Test func discardRemovesTheRowWhenTheServerHasItTombstoned() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c0", tasks: [Fixtures.task(id: "t1")]))
        try db.saveTask(Fixtures.task(id: "t1", title: "local edit"), now: Fixtures.t0)
        let transport = FakeTransport([try .ok(Fixtures.task(id: "t1", deletedAt: Fixtures.instant("2026-11-08T08:00:00Z")))])

        let write = try #require(try db.pendingWrites().first)
        try await client(db, transport).discard(write)
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.task(id: "t1") == nil)
    }

    @Test func discardKeepsTheRowWhenTheServerDoesNotHaveIt() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveTask(Fixtures.task(id: "draft", title: "typed offline"), now: Fixtures.t0)
        let transport = FakeTransport([.error(404, "task draft not found")])

        let write = try #require(try db.pendingWrites().first)
        try await client(db, transport).discard(write)
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.task(id: "draft")?.title == "typed offline")
    }

    @Test func discardDropsTheWriteEvenWhenTheRefetchFails() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveTask(Fixtures.task(id: "t1", title: "local edit"), now: Fixtures.t0)
        let transport = FakeTransport([.error(503, "unavailable")])

        let write = try #require(try db.pendingWrites().first)
        await #expect(throws: SyncError.self) { try await client(db, transport).discard(write) }
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.task(id: "t1")?.title == "local edit")
    }

    @Test func fiveHundredStopsPushingButStillPulls() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveTask(Fixtures.task(id: "a"), now: Fixtures.t0)
        try db.saveTask(Fixtures.task(id: "b"), now: Fixtures.t0)
        try db.saveTask(Fixtures.task(id: "c"), now: Fixtures.t0)
        let pulled = SyncResponse(
            cursor: "after",
            events: [Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")],
            placements: [Fixtures.placement(id: "p1", taskId: "a", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z")],
            calendars: [Fixtures.calendar()])
        let transport = FakeTransport([
            .ok(try Fixtures.putResponse("task", Fixtures.task(id: "a"))),
            .error(500, "internal server error"),
            try .ok(pulled),
        ])

        let client = client(db, transport)
        do {
            try await client.sync()
            Issue.record("expected the push failure to be thrown")
        } catch SyncError.http(let status, _) {
            #expect(status == 500)
        }
        #expect(transport.requests.map(\.path) == ["/api/tasks/a", "/api/tasks/b", "/api/sync"], "stops at the 500, then pulls")
        #expect(try db.pendingWrites().map(\.entityId) == ["b", "c"])
        #expect(await client.lastRejectedWrites.isEmpty)
        // Incoming changes are applied despite the stuck write.
        #expect(try db.cursor() == "after")
        #expect(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc).map(\.id) == ["e1"])
        #expect(try db.placements(in: Fixtures.allTime).map(\.id) == ["p1"])
    }

    @Test func transportErrorStopsPushingButStillPulls() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveTask(Fixtures.task(id: "a"), now: Fixtures.t0)
        let transport = FakeTransport([.failure(NetworkDown()), try .ok(SyncResponse(cursor: "after"))])

        do {
            try await client(db, transport).sync()
            Issue.record("expected a transport error")
        } catch let error as SyncError {
            guard case .transport(let underlying) = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
            #expect(underlying is NetworkDown)
        }
        #expect(try db.pendingWrites().map(\.entityId) == ["a"])
        #expect(try db.cursor() == "after")
    }

    @Test func unauthorizedThrowsAndKeepsRows() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveTask(Fixtures.task(id: "a"), now: Fixtures.t0)
        try db.saveTask(Fixtures.task(id: "b"), now: Fixtures.t0)
        let transport = FakeTransport([.error(401, "unauthorized")])

        do {
            try await client(db, transport).sync()
            Issue.record("expected .unauthorized")
        } catch let error as SyncError {
            guard case .unauthorized = error else {
                Issue.record("expected .unauthorized, got \(error)")
                return
            }
        }
        #expect(transport.requests.count == 1)
        #expect(try db.pendingWrites().map(\.entityId) == ["a", "b"])
    }

    @Test func unauthorizedOnPullThrows() async throws {
        let db = try AppDatabase.inMemory()
        let transport = FakeTransport([.error(401, "unauthorized")])
        do {
            try await client(db, transport).pull()
            Issue.record("expected .unauthorized")
        } catch let error as SyncError {
            guard case .unauthorized = error else {
                Issue.record("expected .unauthorized, got \(error)")
                return
            }
        }
        #expect(try db.cursor() == nil)
    }

    @Test func malformedSuccessBodyIsADecodingError() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveTask(Fixtures.task(id: "a"), now: Fixtures.t0)
        let transport = FakeTransport([.json(status: 200, body: Data("not json".utf8))])
        do {
            _ = try await client(db, transport).push()
            Issue.record("expected .decoding")
        } catch let error as SyncError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
        // The write stays queued: the server may well have accepted it, but we could not confirm.
        #expect(try db.pendingWrites().map(\.entityId) == ["a"])
    }

    @Test(arguments: [false, true])
    func acceptedWriteDoesNotClobberNewerLocalEdit(_ existing: Bool) async throws {
        // A save that lands while the push is in flight must not be overwritten by the server's echo
        // of the older version. We simulate this by saving again inside the fake transport's turn.
        let db = try AppDatabase.inMemory()
        if existing {
            try db.apply(SyncResponse(cursor: "c", tasks: [Fixtures.task(id: "t1", title: "baseline")]))
        }
        let task = Fixtures.task(id: "t1", title: "v1")
        try db.saveTask(task, now: Fixtures.t0)
        let serverEcho = Fixtures.task(id: "t1", title: "v1")

        final class SaveDuringPush: HTTPTransport, @unchecked Sendable {
            let db: AppDatabase
            let body: Data
            init(db: AppDatabase, body: Data) { self.db = db; self.body = body }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                var newer = Fixtures.task(id: "t1", title: "v2")
                newer.updatedAt = Fixtures.instant("2026-11-08T12:00:00Z")
                try db.saveTask(newer, now: Fixtures.instant("2026-11-08T12:00:00Z"))
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let transport = SaveDuringPush(db: db, body: try Fixtures.putResponse("task", serverEcho))
        let pushed = try await SyncClient(database: db, config: config, transport: transport).push()
        #expect(pushed == 1)
        #expect(try db.task(id: "t1")?.title == "v2", "the newer local edit survives")
        let pending = try db.pendingWrites()
        #expect(pending.count == 1, "the newer edit is still queued for the next push")
        #expect(pending.first?.op == (existing ? .patch : .put))
        let data = try #require(pending.first?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["title"] as? String == "v2")
        if existing { #expect(Set(body.keys) == ["title", "expectedRecurrenceRevision"]) }
    }

    // MARK: Events

    @Test func pushSendsAnEventPutAndStoresTheServersCopy() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c0", calendars: [Fixtures.calendar()]))
        var event = Fixtures.event(id: "e1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T17:30:00Z", responseStatus: "tentative")
        event.googleId = ""
        event.summary = "Dentist"
        event.description = "Bring the card"
        try db.saveEvent(event, now: Fixtures.instant("2026-11-08T10:00:00Z"))

        // The server created it in Google: it now has a Google id, a link and the server's updatedAt.
        var serverCopy = event
        serverCopy.googleId = "g-dentist"
        serverCopy.htmlLink = "https://calendar.google.com/event?eid=1"
        serverCopy.updatedAt = Fixtures.instant("2026-11-08T10:00:00.123Z")
        let scheduling = SchedulingResult(placements: [Fixtures.piece(taskId: "t1", start: "2026-11-09T18:00:00Z", end: "2026-11-09T19:00:00Z")])
        let transport = FakeTransport([.ok(try Fixtures.putResponse("event", serverCopy, scheduling: scheduling))])

        #expect(try await client(db, transport).push() == 1)
        let request = try #require(transport.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "/api/events/e1")
        #expect(request.headers["Authorization"] == "Bearer secret-token")
        #expect(request.headers["Content-Type"] == "application/json")
        let requestBody = try #require(request.body)
        let body = try JSONCoding.decoder.decode(EventWrite.self, from: requestBody)
        #expect(body == EventWrite(
            calendarId: "cal", summary: "Dentist", description: "Bring the card",
            startAt: Fixtures.instant("2026-11-09T17:00:00Z"), endAt: Fixtures.instant("2026-11-09T17:30:00Z"),
            allDay: false, responseStatus: "tentative"))
        let keys = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any]).keys
        #expect(Set(keys) == ["calendarId", "summary", "description", "startAt", "endAt", "allDay", "responseStatus"])

        #expect(try db.event(id: "e1") == serverCopy, "the server's copy, Google id included, replaces the row")
        #expect(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc).map(\.googleId) == ["g-dentist"])
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.placements(in: Fixtures.allTime).map(\.taskId) == ["t1"])
    }

    @Test func pushSendsAnEventDeleteAndRemovesTheLocalTombstone() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(
            cursor: "c0",
            events: [
                Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z"),
                Fixtures.event(id: "e2", start: "2026-11-09T12:00:00Z", end: "2026-11-09T13:00:00Z"),
            ],
            calendars: [Fixtures.calendar()]))
        try db.deleteEvent(id: "e1", now: Fixtures.t0)
        #expect(try db.events(in: Fixtures.allTime, calendar: Fixtures.utc).map(\.id) == ["e2"], "hidden before the push")
        let scheduling = SchedulingResult(placements: [Fixtures.piece(taskId: "t1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")])
        let transport = FakeTransport([.ok(try Fixtures.deleteResponse(scheduling: scheduling))])

        #expect(try await client(db, transport).push() == 1)
        let request = try #require(transport.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/api/events/e1")
        #expect(request.body == nil)
        #expect(request.headers["Authorization"] == "Bearer secret-token")
        #expect(try db.event(id: "e1") == nil, "the accepted delete removes the local tombstone")
        #expect(try db.event(id: "e2") != nil)
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.placements(in: Fixtures.allTime).map(\.taskId) == ["t1"], "the freed slot's rescheduling is applied")
    }

    @Test func rejectedEventWriteIsResetToTheServersCopy() async throws {
        let db = try AppDatabase.inMemory()
        let serverCopy = Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        try db.apply(SyncResponse(cursor: "c0", events: [serverCopy], calendars: [Fixtures.calendar()]))
        var moved = serverCopy
        moved.startAt = Fixtures.instant("2026-11-09T14:00:00Z")
        moved.endAt = Fixtures.instant("2026-11-09T15:00:00Z")
        try db.saveEvent(moved, now: Fixtures.t0)
        try db.saveTask(Fixtures.task(id: "later"), now: Fixtures.t0)
        let transport = FakeTransport([
            .error(403, "calendar cal is read-only"),
            try .ok(serverCopy),
            .ok(try Fixtures.putResponse("task", Fixtures.task(id: "later"))),
            try .ok(SyncResponse(cursor: "c1")),
        ])

        let client = client(db, transport)
        #expect(try await client.sync() == 1)
        #expect(transport.requests.map { "\($0.method) \($0.path)" } == [
            "PUT /api/events/e1", "GET /api/events/e1", "PUT /api/tasks/later", "GET /api/sync",
        ])
        #expect(try db.event(id: "e1") == serverCopy, "the move is undone by the server's copy")
        #expect(try db.pendingWrites().isEmpty)
        let rejected = await client.lastRejectedWrites
        #expect(rejected.map(\.write.entity) == [.event])
        #expect(rejected.first?.write.op == .put)
        #expect(rejected.first?.status == 403)
        #expect(rejected.first?.message == "calendar cal is read-only")
    }

    @Test func rejectedEventDeleteOfARowTheServerHasTombstonedRemovesIt() async throws {
        let db = try AppDatabase.inMemory()
        let event = Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        try db.apply(SyncResponse(cursor: "c0", events: [event], calendars: [Fixtures.calendar()]))
        try db.deleteEvent(id: "e1", now: Fixtures.t0)
        let transport = FakeTransport([
            .error(409, "event is deleted"),
            try .ok(Fixtures.event(id: "e1", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z",
                                   deletedAt: Fixtures.instant("2026-11-08T08:00:00Z"))),
            try .ok(SyncResponse(cursor: "c1")),
        ])

        let client = client(db, transport)
        #expect(try await client.sync() == 0)
        #expect(transport.requests.map { "\($0.method) \($0.path)" } == ["DELETE /api/events/e1", "GET /api/events/e1", "GET /api/sync"])
        #expect(try db.event(id: "e1") == nil)
        #expect(try db.pendingWrites().isEmpty)
        #expect(await client.lastRejectedWrites.map(\.status) == [409])
    }

    // MARK: Scheduler endpoints

    @Test func runSchedulerPostsAndAppliesPlacements() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", placements: [
            Fixtures.placement(id: "old", taskId: "t1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z"),
        ]))
        let result = SchedulingResult(placements: [Fixtures.piece(taskId: "t1", start: "2026-11-11T09:00:00Z", end: "2026-11-11T10:00:00Z")])
        let transport = FakeTransport([try .ok(result)])

        try await client(db, transport).runScheduler()
        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/schedule/run")
        #expect(request.headers["Authorization"] == "Bearer secret-token")
        let placements = try db.placements(in: Fixtures.allTime)
        #expect(placements.count == 1)
        #expect(placements.first?.startAt == Fixtures.instant("2026-11-11T09:00:00Z"))
        #expect(placements.first?.id != "old")
    }

    @Test func triggerGoogleSyncPostsAndAppliesPlacements() async throws {
        let db = try AppDatabase.inMemory()
        let result = SchedulingResult(placements: [Fixtures.piece(taskId: "t1", start: "2026-11-11T09:00:00Z", end: "2026-11-11T10:00:00Z")])
        let transport = FakeTransport([try .ok(result)])

        try await client(db, transport).triggerGoogleSync()
        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/google/sync")
        #expect(try db.placements(in: Fixtures.allTime).map(\.taskId) == ["t1"])
    }

    // MARK: Token store

    @Test func inMemoryTokenStoreRoundTrips() throws {
        let store = InMemoryTokenStore()
        #expect(try store.load() == nil)
        try store.save(config)
        #expect(try store.load() == config)
        try store.clear()
        #expect(try store.load() == nil)
    }
}
