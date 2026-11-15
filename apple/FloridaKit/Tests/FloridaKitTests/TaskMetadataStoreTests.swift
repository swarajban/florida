import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct TaskMetadataStoreTests {
    private func body(_ database: AppDatabase) throws -> [String: Any] {
        let data = try #require(try database.pendingWrites().first?.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func v12MigratesPriorStoreWithoutRewritingRowsOrQueuedWrites() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v11-someday-date-decision")
        let olderBody = Data(#"{"title":"Legacy edit","expectedRecurrenceRevision":null}"#.utf8)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO task (id, categoryId, title, durationMinutes, priority, deadlineType, someday,
                                  startAt, completedMinutes, createdAt, updatedAt)
                VALUES ('old', 'work', 'Keep', 30, 'medium', 'none', 1, ?, 0, ?, ?);
                INSERT INTO syncState (key, value) VALUES ('cursor', 'old'), ('other', 'retained');
                """, arguments: [Fixtures.t0, Fixtures.t0, Fixtures.t0])
            var pending = PendingWrite(entity: .task, entityId: "old", op: .patch, body: olderBody, createdAt: Fixtures.t0)
            try pending.insert(db)
        }
        let before = try queue.read { try PendingWrite.fetchAll($0) }
        let database = try AppDatabase(writer: queue)
        let task = try #require(try database.task(id: "old"))
        #expect(task.tags.isEmpty && task.waitingOn == nil && task.waitingUntil == nil)
        #expect(task.someday && task.startAt == Fixtures.t0 && task.updatedAt == Fixtures.t0)
        #expect(try database.pendingWrites() == before && database.cursor() == nil)
        try queue.read { db in
            #expect(try String.fetchOne(db, sql: "SELECT tags FROM task WHERE id = 'old'") == "[]")
            #expect(try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = 'other'") == "retained")
            let columns = try db.columns(in: "task")
            #expect(columns.first { $0.name == "waitingUntil" }?.type == columns.first { $0.name == "startAt" }?.type)
        }
    }

    @Test func creationNormalizesAndCoalescesClearsIntoThePendingPut() throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "new", categoryId: "work", dueAt: Fixtures.t0.addingTimeInterval(3600))
        task.startAt = Fixtures.t0
        task.pinnedStart = Fixtures.t0
        task.tags = [" Work ", "work", "CLIENT", " "]
        task.waitingOn = " \nClient\t"
        task.waitingUntil = Fixtures.t0.addingTimeInterval(600)
        try database.saveTask(task, now: Fixtures.t0)
        let local = try #require(try database.task(id: task.id))
        #expect(local.tags == ["work", "client"] && local.waitingOn == "Client")
        #expect(local.waitingUntil == task.waitingUntil && local.pinnedStart == nil)
        #expect(local.startAt == task.startAt && local.dueAt == task.dueAt && local.someday == task.someday)
        #expect(try database.pendingWrites().first?.op == .put)
        #expect(try body(database)["tags"] as? [String] == local.tags)
        task = local
        task.tags = []
        task.waitingOn = " \n"
        try database.saveTask(task, now: Fixtures.t0)
        #expect(try database.pendingWrites().count == 1 && database.pendingWrites().first?.op == .put)
        let cleared = try body(database)
        #expect(cleared["tags"] as? [String] == [])
        #expect(cleared["waitingOn"] is NSNull && cleared["waitingUntil"] is NSNull)
        #expect(try database.task(id: task.id)?.waitingUntil == nil)
    }

    @Test func editorSparsePatchesNormalizeClearAndPreserveFreshMetadata() throws {
        let database = try AppDatabase.inMemory()
        try database.apply(SyncResponse(cursor: "c", categories: [Fixtures.category(id: "work")]))
        var original = Fixtures.task(id: "task", categoryId: "work")
        try database.apply(SyncResponse(cursor: "c", tasks: [original]))
        var draft = original
        draft.tags = [" Urgent ", "urgent", "CLIENT"]
        draft.waitingOn = " Client "
        draft.waitingUntil = Fixtures.t0
        let mutation = try database.saveTask(draft, original: original, now: Fixtures.t0)
        #expect(mutation.after.tags == ["urgent", "client"] && mutation.after.waitingOn == "Client")
        #expect(try database.pendingWrites().first?.op == .patch)
        #expect(Set(try body(database).keys) == ["tags", "waitingOn", "waitingUntil", "expectedRecurrenceRevision"])
        draft = mutation.after
        draft.waitingUntil = nil
        _ = try database.saveTask(draft, original: mutation.after, now: Fixtures.t0)
        #expect(try body(database)["waitingUntil"] is NSNull)
        #expect(try database.task(id: original.id)?.waitingOn == "Client")
        original.title = "Unrelated stale editor"
        let stale = try database.saveTask(original, original: mutation.before, now: Fixtures.t0)
        #expect(stale.after.tags == ["urgent", "client"] && stale.after.waitingOn == "Client")
        #expect(stale.after.title == original.title && stale.after.waitingUntil == nil)
        try database.updateTask(id: original.id, now: Fixtures.t0) { task in
            task.waitingOn = " \n "
            task.waitingUntil = Fixtures.t0
            return true
        }
        #expect(try body(database)["waitingOn"] is NSNull && body(database)["waitingUntil"] is NSNull)
        #expect(try database.task(id: original.id)?.waitingUntil == nil)
    }

    @Test func invalidMetadataFailsAtomicallyBeforeStoreOrQueueChanges() throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task")
        task.tags = (0..<31).map { "tag-\($0)" }
        #expect(throws: TaskMetadataError.tooManyTags) { try database.saveTask(task) }
        #expect(try database.task(id: task.id) == nil && database.pendingWrites().isEmpty)
        task.tags = ["valid"]
        try database.saveTask(task, now: Fixtures.t0)
        let before = try database.task(id: task.id)
        let queue = try database.pendingWrites()
        #expect(throws: TaskMetadataError.tagTooLong) {
            try database.updateTask(id: task.id) { task in
                task.title = "Must not persist"
                task.tags = [String(repeating: "a", count: 65)]
                return true
            }
        }
        #expect(try database.task(id: task.id) == before && database.pendingWrites() == queue)
        #expect(throws: TaskMetadataError.waitingOnTooLong) {
            try database.updateTask(id: task.id) { task in
                task.waitingOn = String(repeating: "😀", count: 251)
                return true
            }
        }
        #expect(try database.task(id: task.id) == before && database.pendingWrites() == queue)
    }

    @Test(arguments: [false, true])
    func waitingAloneKeepsDateDecisionsAndCannotPin(someday: Bool) throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task", categoryId: "work", dueAt: Fixtures.t0.addingTimeInterval(3600))
        task.startAt = Fixtures.t0
        task.someday = someday
        try database.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.waitingOn = "Client"
        task.pinnedStart = Fixtures.t0
        try database.saveTask(task, now: Fixtures.t0)
        let saved = try #require(try database.task(id: task.id))
        #expect(saved.someday == someday && saved.startAt == task.startAt && saved.dueAt == task.dueAt)
        #expect(saved.pinnedStart == nil)
        #expect(Set(try body(database).keys) == ["waitingOn", "expectedRecurrenceRevision"])
    }

    @Test func explicitSomedayStillClearsDueAndPinForAWaitingTask() throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task", categoryId: "work", dueAt: Fixtures.t0.addingTimeInterval(3600))
        task.startAt = Fixtures.t0
        task.waitingOn = "Client"
        task.waitingUntil = Fixtures.t0.addingTimeInterval(600)
        try database.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.someday = true
        task.pinnedStart = Fixtures.t0
        try database.saveTask(task, now: Fixtures.t0)
        let saved = try #require(try database.task(id: task.id))
        #expect(saved.someday && saved.dueAt == nil && saved.pinnedStart == nil && saved.deadlineType == .none)
        #expect(saved.startAt == task.startAt && saved.waitingOn == task.waitingOn && saved.waitingUntil == task.waitingUntil)
    }

    @Test func clearingWaitingCanPinImmediatelyAndUndoRestoresMetadata() throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task", categoryId: "work")
        task.tags = ["client"]
        task.waitingOn = "Client"
        task.waitingUntil = Fixtures.t0
        try database.apply(SyncResponse(cursor: "c", tasks: [task]))
        var pinned = task
        pinned.waitingOn = nil
        pinned.pinnedStart = Fixtures.t0
        try database.saveTask(pinned, now: Fixtures.t0)
        let saved = try #require(try database.task(id: task.id))
        #expect(saved.waitingUntil == nil)
        #expect(try database.placements(in: Fixtures.allTime).first?.pinned == true)
        let undo = try #require(TaskUndo(from: task, to: saved))
        try database.saveTask(undo.reverted(saved), now: Fixtures.t0)
        #expect(try database.task(id: task.id) == task)
        #expect(try database.placements(in: Fixtures.allTime).isEmpty)
        _ = try database.deleteTask(id: task.id, now: Fixtures.t0)
        _ = try database.restoreTask(task, now: Fixtures.t0)
        let write = try body(database)
        #expect(write["tags"] as? [String] == task.tags && write["waitingOn"] as? String == "Client")
        #expect(write["waitingUntil"] as? String == JSONCoding.formatInstant(Fixtures.t0))
    }

    @Test func optimisticWaitingRemovesStaleBlocksButAllowsFollowUpAtTheBoundary() throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task", categoryId: "work", dueAt: Fixtures.t0.addingTimeInterval(7200))
        task.startAt = Fixtures.t0
        task.pinnedStart = Fixtures.t0
        let until = Fixtures.t0.addingTimeInterval(3600)
        let old = Placement(id: "old", taskId: task.id, startAt: Fixtures.t0, endAt: until, pinned: true, computedAt: Fixtures.t0)
        let eligible = Placement(id: "eligible", taskId: task.id, startAt: until,
                                 endAt: until.addingTimeInterval(3600), pinned: false, computedAt: Fixtures.t0)
        let optional = OptionalPlacement(id: "optional", taskId: task.id, blockId: "block", startAt: old.startAt,
                                         endAt: old.endAt, computedAt: Fixtures.t0)
        let problem = UnscheduledTask(taskId: task.id, reason: "no_capacity", unplacedMinutes: 30, computedAt: Fixtures.t0)
        try database.apply(SyncResponse(cursor: "c", tasks: [task], placements: [old], optionalPlacements: [optional], unscheduled: [problem]))
        task.waitingOn = " Client "
        task.waitingUntil = until
        try database.saveTask(task, now: Fixtures.t0)
        #expect(try database.placements(in: Fixtures.allTime).isEmpty)
        #expect(try database.optionalPlacements().isEmpty && database.unscheduled().isEmpty)
        #expect(try database.task(id: task.id)?.pinnedStart == nil)
        #expect(try body(database)["pinnedStart"] is NSNull)
        try database.apply(SyncResponse(cursor: "stale", placements: [old, eligible], optionalPlacements: [optional], unscheduled: [problem]))
        #expect(try database.placements(in: Fixtures.allTime) == [eligible])
        #expect(try database.scheduledBlocks(in: Fixtures.allTime).map(\.placement) == [eligible])
        #expect(try database.placementsByTask()[task.id] == [eligible])
        task = try #require(try database.task(id: task.id))
        task.waitingUntil = nil
        try database.saveTask(task, now: Fixtures.t0)
        try database.apply(SyncResponse(cursor: "still-stale", placements: [old, eligible], unscheduled: [problem]))
        #expect(try database.placements(in: Fixtures.allTime).isEmpty && database.unscheduled().isEmpty)
    }

    @Test func authoritativeFollowUpSyncKeepsEligibleBlocksAndFiltersPins() throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task", categoryId: "work")
        task.tags = ["client"]
        task.waitingOn = "Client"
        task.waitingUntil = Fixtures.t0
        let allowed = Placement(id: "allowed", taskId: task.id, startAt: Fixtures.t0,
                                endAt: Fixtures.t0.addingTimeInterval(600), pinned: false, computedAt: Fixtures.t0)
        var pin = allowed
        pin.id = "pin"
        pin.pinned = true
        var early = allowed
        early.id = "early"
        early.startAt = Fixtures.t0.addingTimeInterval(-1)
        let optional = OptionalPlacement(id: "optional", taskId: task.id, blockId: "block", startAt: allowed.startAt,
                                         endAt: allowed.endAt, computedAt: Fixtures.t0)
        try database.apply(SyncResponse(cursor: "c", tasks: [task], placements: [allowed, pin, early], optionalPlacements: [optional]))
        #expect(try database.task(id: task.id) == task)
        #expect(try database.pendingWrites().isEmpty)
        #expect(try database.placements(in: Fixtures.allTime) == [allowed])
        #expect(try database.optionalPlacements() == [optional])
    }

    @Test func syncPushesNormalizedMetadataAndExplicitPatchClears() async throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task", categoryId: "work")
        task.tags = [" CLIENT ", "client"]
        task.waitingOn = " Client "
        task.waitingUntil = Fixtures.t0
        try database.saveTask(task, now: Fixtures.t0)
        task = try #require(try database.task(id: task.id))
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let transport = FakeTransport([.ok(try Fixtures.putResponse("task", task))])
        #expect(try await SyncClient(database: database, config: config, transport: transport).push() == 1)
        let request = try #require(transport.requests.first)
        #expect(request.method == "PUT")
        let sent = try JSONCoding.decoder.decode(TaskWrite.self, from: #require(request.body))
        #expect(sent.tags == ["client"] && sent.waitingOn == "Client" && sent.waitingUntil == Fixtures.t0)
        #expect(try database.task(id: task.id) == task && database.pendingWrites().isEmpty)
        task.tags = []
        task.waitingOn = nil
        task.waitingUntil = nil
        try database.saveTask(task, now: Fixtures.t0)
        let clearTransport = FakeTransport([.ok(try Fixtures.putResponse("task", task))])
        #expect(try await SyncClient(database: database, config: config, transport: clearTransport).push() == 1)
        #expect(clearTransport.requests.first?.method == "PATCH")
        let clearData = try #require(clearTransport.requests.first?.body)
        let clear = try #require(JSONSerialization.jsonObject(with: clearData) as? [String: Any])
        #expect(clear["tags"] as? [String] == [])
        #expect(clear["waitingOn"] is NSNull && clear["waitingUntil"] is NSNull)
        #expect(try database.task(id: task.id) == task && database.pendingWrites().isEmpty)
    }
}
