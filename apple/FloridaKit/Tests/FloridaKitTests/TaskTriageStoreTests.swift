import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import FloridaKit

@Suite struct TaskTriageStoreTests {
    let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test-token")

    func body(_ write: PendingWrite) throws -> [String: Any] {
        let data = try #require(write.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func v11UpgradesMainV10WithoutRewritingSourceOrAutomaticBlockingOrQueuedBodies() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v10-automatic-day-blocking")
        let source = TaskSource.from(url: "https://github.com/acme/project/issues/42")!
        let sourceJSON = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        let queued = [
            PendingWrite(entity: .task, entityId: "work", op: .put,
                         body: Data(#"{ "title": "Legacy", "source": {"url":"https://example.com","title":"Example","kind":"web"} }"#.utf8), createdAt: Fixtures.t0),
            PendingWrite(entity: .task, entityId: "patch", op: .patch,
                         body: Data(#"{ "source": null, "expectedRecurrenceRevision": "old" }"#.utf8), createdAt: Fixtures.t0),
        ]
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO task (id, categoryId, title, durationMinutes, priority, deadlineType, source,
                                  completedMinutes, createdAt, updatedAt)
                VALUES ('work', 'work', 'Retained', 30, 'medium', 'none', ?, 0, ?, ?)
                """, arguments: [sourceJSON, Fixtures.t0, Fixtures.t0])
            try db.execute(sql: """
                INSERT INTO event (id, calendarId, googleId, status, allDay, blocksDay, autoBlocksDay, blockingReason, updatedAt)
                VALUES ('event', 'calendar', 'google', 'confirmed', 1, 0, 1, 'Company holiday', ?);
                INSERT INTO googleAccount (id, email, label, displayName, updatedAt)
                VALUES ('account', 'test@example.com', 'work', 'Test User', ?);
                INSERT INTO syncState (key, value) VALUES ('cursor', 'v10-cursor');
                """, arguments: [Fixtures.t0, Fixtures.t0])
            for var write in queued { try write.insert(db) }
        }
        let before = try queue.read { try PendingWrite.order(Column("seq")).fetchAll($0) }
        let database = try AppDatabase(writer: queue)
        let task = try #require(try database.task(id: "work"))
        #expect(task.someday && task.source == source && task.updatedAt == Fixtures.t0)
        #expect(try database.pendingWrites() == before)
        #expect(try database.cursor() == nil)
        try queue.read { db in
            let event = try #require(try CalendarEvent.fetchOne(db, id: "event"))
            #expect(event.blocksDay == false && event.autoBlocksDay == true)
            #expect(event.blockingReason == "Company holiday")
            #expect(try GoogleAccount.fetchOne(db, id: "account")?.displayName == "Test User")
            #expect(try AppDatabase.migrator.appliedMigrations(db).suffix(3) == [
                "v9-task-source", "v10-automatic-day-blocking", "v11-someday-date-decision",
            ])
        }
    }

    @Test(arguments: ["v8-event-blocks-day", "v10-automatic-day-blocking"])
    func migrationBackfillsOnlyCategorizedUndatedTasksAndPreservesLegacyQueue(version: String) throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: version)
        let writes = [
            PendingWrite(entity: .task, entityId: "work", op: .put, body: Data("{\"title\":\"Legacy\"}".utf8), createdAt: Fixtures.t0),
            PendingWrite(entity: .task, entityId: "inbox", op: .patch, body: Data("{\"dueAt\":null,\"expectedRecurrenceRevision\":null}".utf8), createdAt: Fixtures.t0),
            PendingWrite(entity: .task, entityId: "deleted", op: .delete, body: nil, createdAt: Fixtures.t0),
            PendingWrite(entity: .category, entityId: "other", op: .put, body: Data("{\"name\":\"Other\"}".utf8), createdAt: Fixtures.t0),
        ]
        try queue.write { db in
            for (id, category, dueAt) in [
                ("work", "work", nil), ("inbox", "inbox", nil),
                ("dated", "work", "2026-11-09 00:00:00.000"), ("inbox-dated", "inbox", "2026-11-09 00:00:00.000"),
            ] as [(String, String, String?)] {
                try db.execute(sql: """
                    INSERT INTO task (id, categoryId, title, durationMinutes, priority, deadlineType,
                                      dueAt, completedMinutes, createdAt, updatedAt)
                    VALUES (?, ?, ?, 30, 'medium', 'none', ?, 0, ?, ?)
                    """, arguments: [id, category, id, dueAt, Fixtures.t0, Fixtures.t0])
            }
            for var write in writes { try write.insert(db) }
            for category in ["inbox", "work"] {
                for mask in 0..<8 {
                    let date = "2026-11-09 00:00:00.000"
                    try db.execute(sql: """
                        INSERT INTO task (id, categoryId, title, durationMinutes, priority, deadlineType,
                                          dueAt, startAt, pinnedStart, completedMinutes, createdAt, updatedAt)
                        VALUES (?, ?, 'Matrix', 30, 'medium', 'none', ?, ?, ?, 0, ?, ?)
                        """, arguments: ["\(category)-\(mask)", category, mask & 1 != 0 ? date : nil,
                                         mask & 2 != 0 ? date : nil, mask & 4 != 0 ? date : nil, Fixtures.t0, Fixtures.t0])
                }
            }
            try db.execute(sql: "INSERT INTO syncState (key, value) VALUES ('cursor', 'old'), ('other', 'retained')")
        }
        let before = try queue.read { try PendingWrite.order(Column("seq")).fetchAll($0) }
        let db = try AppDatabase(writer: queue)
        #expect(try db.task(id: "work")?.someday == true)
        #expect(try db.task(id: "work")?.needsTriage == false)
        #expect(try db.task(id: "inbox")?.someday == false)
        #expect(try db.task(id: "inbox")?.needsTriage == true)
        #expect(try db.task(id: "dated")?.someday == false)
        #expect(try db.task(id: "inbox-dated")?.someday == false)
        #expect(try db.task(id: "work")?.updatedAt == Fixtures.t0)
        #expect(try db.cursor() == nil)
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT value FROM syncState WHERE key = 'other'") } == "retained")
        #expect(try db.pendingWrites() == before)
        for category in ["inbox", "work"] {
            for mask in 0..<8 {
                #expect(try db.task(id: "\(category)-\(mask)")?.someday == (category == "work" && mask == 0))
            }
        }
        try db.saveTask(try #require(try db.task(id: "work")))
        #expect(try db.pendingWrites() == before)
    }

    @Test(arguments: ["v8-event-blocks-day", "v10-automatic-day-blocking"])
    func migratedLegacyPutIsPushedUnchangedBeforeTheFullAuthoritativePull(version: String) async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: version)
        var task = Fixtures.task(id: "t1", categoryId: "work")
        var object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(TaskWrite(task))) as? [String: Any])
        object.removeValue(forKey: "someday")
        let legacyBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO task (id, categoryId, title, durationMinutes, priority, deadlineType,
                                  completedMinutes, createdAt, updatedAt)
                VALUES ('t1', 'work', 't1', 60, 'medium', 'none', 0, ?, ?)
                """, arguments: [Fixtures.t0, Fixtures.t0])
            var write = PendingWrite(entity: .task, entityId: "t1", op: .put, body: legacyBody, createdAt: Fixtures.t0)
            try write.insert(db)
            try db.execute(sql: "INSERT INTO syncState (key, value) VALUES ('cursor', 'old')")
        }
        let db = try AppDatabase(writer: queue)
        #expect(try db.task(id: task.id)?.someday == true)
        task.someday = true
        let transport = FakeTransport([
            .ok(try Fixtures.putResponse("task", task)),
            try .ok(SyncResponse(cursor: "fresh", tasks: [task])),
        ])
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.sync() == 1)
        #expect(transport.requests.map(\.method) == ["PUT", "GET"])
        #expect(transport.requests.first?.body == legacyBody)
        #expect(transport.requests.last?.path == "/api/sync")
        #expect(transport.requests.last?.query.isEmpty == true)
        #expect(try db.task(id: task.id) == task)
        #expect(try db.cursor() == "fresh")
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test(arguments: [false, true])
    func editsQueueOnlyTheDateDecisionInBothDirections(notNeeded: Bool) throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "t1", categoryId: "work")
        task.someday = !notNeeded
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.someday = notNeeded
        try db.saveTask(task, now: Fixtures.t0)
        let write = try #require(try db.pendingWrites().first)
        #expect(write.op == .patch)
        let fields = try body(write)
        #expect(Set(fields.keys) == ["someday", "expectedRecurrenceRevision"])
        #expect(fields["someday"] as? Bool == notNeeded)
        #expect(fields["expectedRecurrenceRevision"] is NSNull)
        #expect(try db.task(id: task.id)?.someday == notNeeded)
        let pending = try db.pendingWrites()
        try db.saveTask(task)
        #expect(try db.pendingWrites() == pending)
    }

    @Test func creationAndSubsequentEditsCoalesceWithoutDroppingTheDecision() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "t1")
        try db.saveTask(task)
        #expect(try body(#require(try db.pendingWrites().first))["someday"] as? Bool == false)
        task.someday = true
        try db.saveTask(task)
        task.title = "Edited"
        try db.saveTask(task)
        var writes = try db.pendingWrites()
        #expect(writes.count == 1 && writes.first?.op == .put)
        var decoded = try JSONCoding.decoder.decode(TaskWrite.self, from: #require(writes.first?.body))
        #expect(decoded.someday == true && decoded.title == "Edited")
        #expect(try db.task(id: task.id)?.needsTriage == true)
        task.categoryId = "work"
        try db.saveTask(task)
        #expect(try db.task(id: task.id)?.needsTriage == false)
        task.someday = false
        try db.saveTask(task)
        writes = try db.pendingWrites()
        decoded = try JSONCoding.decoder.decode(TaskWrite.self, from: #require(writes.first?.body))
        #expect(writes.count == 1 && decoded.someday == false)
        #expect(try db.task(id: task.id)?.needsTriage == true)
    }

    @Test func unrelatedEditOmitsTheDecisionFromAnExistingLegacyPatch() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "t1", categoryId: "work")
        task.someday = true
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        let legacyBody = Data("{\"notes\":null,\"expectedRecurrenceRevision\":\"old-revision\"}".utf8)
        try db.requeue(PendingWrite(entity: .task, entityId: task.id, op: .patch, body: legacyBody, createdAt: Fixtures.t0))
        task.title = "Renamed"
        try db.saveTask(task)
        let fields = try body(#require(try db.pendingWrites().first))
        #expect(Set(fields.keys) == ["title", "notes", "expectedRecurrenceRevision"])
        #expect(fields["expectedRecurrenceRevision"] as? String == "old-revision")
        #expect(fields["notes"] is NSNull)
        #expect(try db.task(id: task.id)?.someday == true)
    }

    @Test(arguments: [false, true])
    func syncPushesTheExplicitPatchAndAppliesTheServerDecision(notNeeded: Bool) async throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "t1", categoryId: "work")
        task.someday = !notNeeded
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.someday = notNeeded
        try db.saveTask(task)
        let transport = FakeTransport([.ok(try Fixtures.putResponse("task", task))])
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 1)
        let request = try #require(transport.requests.first)
        #expect(request.method == "PATCH" && request.path == "/api/tasks/t1")
        let data = try #require(request.body)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["someday"] as? Bool == notNeeded)
        #expect(try db.task(id: task.id) == task)
        #expect(try db.pendingWrites().isEmpty)
        task.someday = !notNeeded
        let pull = FakeTransport([try .ok(SyncResponse(cursor: "next", tasks: [task]))])
        try await SyncClient(database: db, config: config, transport: pull).pull()
        #expect(try db.task(id: task.id) == task)
    }

    @Test func failedPushAndPullPreserveTheQueuedDecision() async throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "t1", categoryId: "work")
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.someday = true
        try db.saveTask(task)
        let before = try db.pendingWrites()
        task.someday = false
        let transport = FakeTransport([.failure(NetworkDown()), try .ok(SyncResponse(cursor: "next", tasks: [task]))])
        let client = SyncClient(database: db, config: config, transport: transport)
        await #expect(throws: SyncError.self) { try await client.sync() }
        #expect(try db.task(id: task.id)?.someday == true)
        #expect(try db.pendingWrites() == before)
        #expect(try db.cursor() == "next")
    }

    @Test func atomicDateActionsNeverRestoreMissingDeletedOrCompletedTasks() throws {
        for state in ["missing", "deleted", "completed"] {
            for decision in [AppDatabase.TaskDateDecision.someday, .due(Fixtures.t0), .start(Fixtures.t0)] {
                let db = try AppDatabase.inMemory()
                var task = Fixtures.task(id: "stale", categoryId: "work")
                if state == "deleted" { task.deletedAt = Fixtures.t0 }
                if state == "completed" { task.completedAt = Fixtures.t0 }
                if state != "missing" { try db.writer.write { try task.insert($0) } }
                let before = try db.task(id: task.id)
                #expect(try db.setTaskDateDecision(id: task.id, decision: decision) == nil)
                #expect(try db.task(id: task.id) == before)
                #expect(try db.pendingWrites().isEmpty)
            }
        }
    }

    @Test func atomicDateActionsPreserveFreshFieldsAndDoNotQueueNoOps() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "current", categoryId: "work")
        task.title = "Latest title from sync"
        task.notes = "Latest notes"
        task.someday = true
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        let changed = try #require(try db.setTaskDateDecision(id: task.id, decision: .due(Fixtures.t0)))
        #expect(changed.before == task)
        #expect(changed.after.title == task.title && changed.after.notes == task.notes)
        #expect(changed.after.dueAt == Fixtures.t0)
        #expect(!changed.after.someday)
        let noDate = try #require(try db.setTaskDateDecision(id: task.id, decision: .someday))
        #expect(noDate.after.title == task.title && noDate.after.notes == task.notes)
        #expect(noDate.after.dueAt == nil && noDate.after.someday)
        let pending = try db.pendingWrites()
        #expect(try db.setTaskDateDecision(id: task.id, decision: .someday) == nil)
        #expect(try db.pendingWrites() == pending)
    }

    @Test func atomicDateActionPropagatesReadFailureWithoutQueuingWrite() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { try $0.execute(sql: "DROP TABLE task") }
        #expect(throws: DatabaseError.self) {
            try db.setTaskDateDecision(id: "missing", decision: .someday)
        }
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func unrelatedSavePreservesNoDateDecisionEvenWhenLegacyClientAddedADate() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "dated", categoryId: "work")
        task.dueAt = Fixtures.t0
        task.deadlineType = .soft
        task.someday = true
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.title = "Renamed without touching dates"
        try db.saveTask(task)
        #expect(try db.task(id: task.id)?.someday == true)
        let fields = try body(#require(try db.pendingWrites().first))
        #expect(fields["title"] as? String == task.title)
        #expect(fields["someday"] == nil)
        #expect(fields["dueAt"] == nil)
    }

    @Test func staleAcceptedWriteCannotOverwriteANewerDateDecision() async throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "t1", categoryId: "work")
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.someday = true
        try db.saveTask(task)
        final class ChangeDuringPush: HTTPTransport, @unchecked Sendable {
            let database: AppDatabase
            let body: Data
            init(database: AppDatabase, body: Data) { self.database = database; self.body = body }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                var task = try #require(try database.task(id: "t1"))
                task.someday = false
                try database.saveTask(task)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let transport = ChangeDuringPush(database: db, body: try Fixtures.putResponse("task", task))
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 1)
        #expect(try db.task(id: task.id)?.someday == false)
        let writes = try db.pendingWrites()
        #expect(writes.count == 1 && writes.first?.op == .patch)
        #expect(try body(#require(writes.first))["someday"] as? Bool == false)
    }

    @Test func atomicSomedayClearsContradictionsAndPreservesTheStartAcrossTheTruthTable() throws {
        for mask in 0..<8 {
            let db = try AppDatabase.inMemory()
            var task = Fixtures.task(id: "matrix", categoryId: "work")
            task.dueAt = mask & 1 != 0 ? Fixtures.t0 : nil
            task.startAt = mask & 2 != 0 ? Fixtures.t0 : nil
            task.pinnedStart = mask & 4 != 0 ? Fixtures.t0 : nil
            task.deadlineType = task.dueAt == nil ? .none : .hard
            try db.apply(SyncResponse(cursor: "c", tasks: [task]))
            let change = try #require(try db.setTaskDateDecision(id: task.id, decision: .someday, now: Fixtures.t0))
            #expect(change.before == task)
            #expect(change.after.someday)
            #expect(change.after.startAt == task.startAt)
            #expect(change.after.dueAt == nil && change.after.pinnedStart == nil && change.after.deadlineType == .none)
            let fields = try body(#require(try db.pendingWrites().first))
            #expect(fields["someday"] as? Bool == true)
            #expect(fields["startAt"] == nil)
            if task.dueAt != nil { #expect(fields["dueAt"] is NSNull) }
            if task.pinnedStart != nil { #expect(fields["pinnedStart"] is NSNull) }
            let queued = try db.pendingWrites()
            #expect(try db.setTaskDateDecision(id: task.id, decision: .someday) == nil)
            #expect(try db.pendingWrites() == queued)
        }
    }

    @Test func explicitSameDatesResumeButUnrelatedSavesPreserveSomeday() throws {
        for field in ["dueAt", "startAt", "pinnedStart"] {
            for same in [false, true] {
                let db = try AppDatabase.inMemory()
                var task = Fixtures.task(id: "same", categoryId: "work")
                task.dueAt = field == "dueAt" ? Fixtures.t0 : nil
                task.startAt = field == "startAt" ? Fixtures.t0 : nil
                task.pinnedStart = field == "pinnedStart" ? Fixtures.t0 : nil
                task.someday = true
                try db.apply(SyncResponse(cursor: "c", tasks: [task]))
                task.title = "Only a title edit"
                try db.saveTask(task)
                #expect(try db.task(id: task.id)?.someday == true)
                #expect(try body(#require(try db.pendingWrites().first))["someday"] == nil)
                let date = same ? Fixtures.t0 : Fixtures.t0.addingTimeInterval(60)
                if field == "pinnedStart" {
                    task.pinnedStart = date
                    task.someday = false
                    try db.saveTask(task)
                    #expect(try db.task(id: task.id)?.someday == false)
                    #expect(try body(#require(try db.pendingWrites().first))["someday"] as? Bool == false)
                } else {
                    let decision: AppDatabase.TaskDateDecision = field == "dueAt" ? .due(date) : .start(date)
                    let changed = try #require(try db.setTaskDateDecision(id: task.id, decision: decision))
                    #expect(!changed.after.someday)
                    #expect(try body(#require(try db.pendingWrites().first))["someday"] as? Bool == false)
                    let queued = try db.pendingWrites()
                    #expect(try db.setTaskDateDecision(id: task.id, decision: decision) == nil)
                    #expect(try db.pendingWrites() == queued)
                }
            }
        }
    }

    @Test func optimisticDateMutationsClearSomedayAndQueueOnlyExplicitChanges() throws {
        for field in ["dueAt", "startAt", "pinnedStart"] {
            let db = try AppDatabase.inMemory()
            var task = Fixtures.task(id: "optimistic", categoryId: "work")
            task.someday = true
            task.startAt = Fixtures.t0
            try db.apply(SyncResponse(cursor: "c", tasks: [task]))
            let date = Fixtures.t0.addingTimeInterval(60)
            switch field {
            case "dueAt": task.dueAt = date
            case "startAt": task.startAt = date
            default: task.pinnedStart = date
            }
            task.someday = false
            try db.saveTask(task)
            #expect(try db.task(id: task.id)?.someday == false)
            let fields = try body(#require(try db.pendingWrites().first))
            #expect(Set(fields.keys) == [field, "someday", "expectedRecurrenceRevision"])
            #expect(fields["someday"] as? Bool == false)
            if field == "pinnedStart" {
                #expect(try db.placementsByTask()[task.id]?.first?.startAt == date)
            }
        }
    }

    @Test func editingStartThenReenablingSomedayPersistsAndPushesTheFinalDecision() async throws {
        let db = try AppDatabase.inMemory()
        var original = Fixtures.task(id: "reenabled", categoryId: "work")
        original.someday = true
        original.startAt = Fixtures.t0
        try db.apply(SyncResponse(cursor: "c", tasks: [original]))
        var draft = original
        draft.startAt = Fixtures.t0.addingTimeInterval(3600)
        draft.someday = false
        draft.someday = true
        try db.saveTask(draft, now: Fixtures.t0)
        #expect(try db.task(id: draft.id) == draft)
        let write = try #require(try db.pendingWrites().first)
        #expect(write.op == .patch)
        let fields = try body(write)
        #expect(Set(fields.keys) == ["startAt", "someday", "expectedRecurrenceRevision"])
        #expect(fields["someday"] as? Bool == true)
        func serverCopy(applying patch: [String: Any]) throws -> TaskItem {
            var server = original
            if let start = patch["startAt"] as? String {
                let date: Date = try #require(JSONCoding.parseInstant(start))
                server.startAt = date
                server.someday = false
            }
            if let someday = patch["someday"] as? Bool { server.someday = someday }
            return server
        }
        let server = try serverCopy(applying: fields)
        #expect(server == draft)
        var omittedDecision = fields
        omittedDecision.removeValue(forKey: "someday")
        #expect(try !serverCopy(applying: omittedDecision).someday)
        let transport = FakeTransport([.ok(try Fixtures.putResponse("task", server))])
        #expect(try await SyncClient(database: db, config: config, transport: transport).push() == 1)
        let request = try #require(transport.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.body == write.body)
        #expect(try db.task(id: draft.id) == server)
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func finalSomedayChoiceWinsOverDateEditsAndClearsContradictions() throws {
        for field in ["dueAt", "startAt", "pinnedStart"] {
            let db = try AppDatabase.inMemory()
            var task = Fixtures.task(id: "final-choice", categoryId: "work")
            task.someday = true
            task.startAt = Fixtures.t0
            try db.apply(SyncResponse(cursor: "c", tasks: [task]))
            let date = Fixtures.t0.addingTimeInterval(3600)
            switch field {
            case "dueAt": task.dueAt = date
            case "startAt": task.startAt = date
            default: task.pinnedStart = date
            }
            try db.saveTask(task)
            let saved = try #require(try db.task(id: task.id))
            #expect(saved.someday)
            #expect(saved.dueAt == nil && saved.pinnedStart == nil)
            #expect(saved.startAt == (field == "startAt" ? date : Fixtures.t0))
            if field == "startAt" {
                #expect(try body(#require(try db.pendingWrites().first))["someday"] as? Bool == true)
            } else {
                #expect(try db.pendingWrites().isEmpty)
            }
        }
    }

    @Test(arguments: [ProjectStatus.active, .onHold, .done])
    func explicitPinAndFinalSomedayRespectProjectState(_ status: ProjectStatus) throws {
        let db = try AppDatabase.inMemory()
        var project = Project(id: "project", name: "Project", createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        project.status = status
        var original = Fixtures.task(id: "project-task", categoryId: "work")
        original.projectId = project.id
        original.someday = true
        original.startAt = Fixtures.t0
        original.source = TaskSource.from(url: "https://example.com/project-task")
        try db.apply(SyncResponse(cursor: "initial", tasks: [original], projects: [project]))
        var pinned = original
        pinned.someday = false
        pinned.pinnedStart = Fixtures.t0.addingTimeInterval(600)
        let mutation = try db.saveTask(pinned, original: original, somedayIntent: false, dateEdits: [.pin])
        #expect(!mutation.after.someday)
        #expect(mutation.after.startAt == original.startAt && mutation.after.source == original.source)
        #expect(try db.placements(in: Fixtures.allTime).count == (status == .active ? 1 : 0))
        #expect(try body(#require(try db.pendingWrites().first))["someday"] as? Bool == false)
        var deferred = mutation.after
        deferred.someday = true
        let final = try db.saveTask(deferred, original: mutation.after, somedayIntent: true)
        #expect(final.after.someday && final.after.pinnedStart == nil && final.after.dueAt == nil)
        #expect(final.after.startAt == original.startAt && final.after.source == original.source)
        let stale = Placement(id: "stale", taskId: original.id, startAt: Fixtures.t0,
                              endAt: Fixtures.t0.addingTimeInterval(3600), pinned: true, computedAt: Fixtures.t0)
        let optional = OptionalPlacement(id: "optional", taskId: original.id, blockId: "evening",
                                         startAt: stale.startAt, endAt: stale.endAt, computedAt: Fixtures.t0)
        let unscheduled = UnscheduledTask(taskId: original.id, reason: "no_capacity", unplacedMinutes: 30, computedAt: Fixtures.t0)
        try db.apply(SyncResponse(cursor: "stale", placements: [stale], optionalPlacements: [optional], unscheduled: [unscheduled]))
        #expect(try db.placements(in: Fixtures.allTime).isEmpty)
        #expect(try db.optionalPlacements().isEmpty && db.unscheduled().isEmpty)
        #expect(try body(#require(try db.pendingWrites().first))["someday"] as? Bool == true)
    }

    @Test func optimisticSomedayRemovesLocalBlocksAndFiltersStaleSchedulerOutput() async throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "paused", categoryId: "work", dueAt: Fixtures.t0)
        task.pinnedStart = Fixtures.t0
        task.startAt = Fixtures.t0
        let placement = Placement(id: "stale", taskId: task.id, startAt: Fixtures.t0,
                                  endAt: Fixtures.t0.addingTimeInterval(3600), pinned: true, computedAt: Fixtures.t0)
        let optional = OptionalPlacement(id: "optional", taskId: task.id, blockId: "evening", startAt: placement.startAt,
                                         endAt: placement.endAt, computedAt: Fixtures.t0)
        let unscheduled = UnscheduledTask(taskId: task.id, reason: "no_capacity", unplacedMinutes: 30, computedAt: Fixtures.t0)
        try db.apply(SyncResponse(cursor: "c", tasks: [task], placements: [placement], optionalPlacements: [optional], unscheduled: [unscheduled]))
        task.someday = true
        try db.saveTask(task)
        let saved = try #require(try db.task(id: task.id))
        #expect(saved.someday && saved.dueAt == nil && saved.pinnedStart == nil && saved.startAt == task.startAt)
        #expect(try db.placements(in: Fixtures.allTime).isEmpty)
        #expect(try db.optionalPlacements().isEmpty)
        #expect(try db.unscheduled().isEmpty)
        try db.apply(SyncResponse(cursor: "stale", placements: [placement], optionalPlacements: [optional], unscheduled: [unscheduled]))
        #expect(try db.placementsByTask().isEmpty)
        #expect(try db.scheduledBlocks(in: Fixtures.allTime).isEmpty)
        #expect(try db.placements(in: Fixtures.allTime).isEmpty)
        #expect(try db.optionalPlacements().isEmpty)
        #expect(try db.unscheduled().isEmpty)
        var placements = db.observePlacements().makeAsyncIterator()
        var problems = db.observeUnscheduled().makeAsyncIterator()
        #expect(try await placements.next()?.isEmpty == true)
        #expect(try await problems.next()?.isEmpty == true)
    }
}
