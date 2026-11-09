import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct TaskRecurrenceStoreTests {
    private let rule = TaskRecurrence(
        frequency: .week, interval: 2, timeZone: "America/Los_Angeles", startDate: "2026-11-09",
        weekdays: [1, 3], endDate: "2027-11-09")

    private func occurrence(_ id: String, date: String = "2026-11-09") -> TaskItem {
        var task = Fixtures.task(id: id)
        task.recurrence = rule
        task.recurrenceSeriesId = "series"
        task.recurrenceDate = date
        task.recurrenceRevision = "revision-1"
        return task
    }

    private func queuedBody(_ db: AppDatabase) throws -> [String: Any] {
        let write = try #require(try db.pendingWrites().first)
        let body = try #require(write.body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func v2MigrationPreservesRowsAndQueueAndInvalidatesCursor() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO task (id, categoryId, title, durationMinutes, priority, deadlineType, completedMinutes,
                                  createdAt, updatedAt)
                VALUES ('t1', 'inbox', 'Keep me', 60, 'medium', 'none', 0, '2026-11-08 00:00:00.000', '2026-11-08 00:00:00.000');
                INSERT INTO pendingWrite (entity, entityId, op, body, createdAt)
                VALUES ('task', 't1', 'put', X'7B7D', '2026-11-08 00:00:00.000');
                INSERT INTO syncState (key, value) VALUES ('cursor', 'old-cursor');
                INSERT INTO syncState (key, value) VALUES ('other', 'keep');
                """)
        }
        let db = try AppDatabase(writer: queue)
        let task = try #require(try db.task(id: "t1"))
        #expect(task.title == "Keep me")
        #expect(task.recurrence == nil && task.recurrenceSeriesId == nil && task.recurrenceDate == nil)
        #expect(task.recurrenceRevision == nil)
        #expect(try db.cursor() == nil)
        #expect(try db.pendingWrites().first?.body == Data("{}".utf8))
        #expect(try db.writer.read { try String.fetchOne($0, sql: "SELECT value FROM syncState WHERE key = 'other'") } == "keep")
    }

    @Test func recurrenceIsJSONTextAndMetadataSurvivesQueueAndCompletion() throws {
        let db = try AppDatabase.inMemory()
        let task = occurrence("t1")
        let future = occurrence("t2", date: "2026-11-11")
        try db.apply(SyncResponse(cursor: "c", tasks: [task, future]))
        #expect(try db.task(id: task.id) == task)
        let json = try #require(try db.writer.read {
            try String.fetchOne($0, sql: "SELECT recurrence FROM task WHERE id = 't1'")
        })
        #expect(try JSONDecoder().decode(TaskRecurrence.self, from: Data(json.utf8)) == rule)

        let doneAt = Fixtures.instant("2026-11-09T17:00:00Z")
        try db.completeTask(id: task.id, at: doneAt)
        var stored = try #require(try db.task(id: task.id))
        #expect(stored.completedAt == doneAt && stored.completedMinutes == task.durationMinutes)
        #expect(stored.recurrence == rule && stored.recurrenceSeriesId == "series" && stored.recurrenceDate == "2026-11-09")
        #expect(try db.task(id: future.id) == future, "completion is occurrence-only, even offline")
        #expect(try db.openTasks().map(\.id) == [future.id])
        var pending = try db.pendingWrites()
        #expect(pending.count == 1)
        #expect(pending.first?.op == .patch)
        let completedWrite = try queuedBody(db)
        #expect(Set(completedWrite.keys) == ["completedAt", "completedMinutes"])
        #expect(completedWrite["completedAt"] as? String == JSONCoding.formatInstant(doneAt))
        #expect(completedWrite["completedMinutes"] as? Int == task.durationMinutes)

        // Reopen is the same local write used by completion Undo, and collapses the queued patch.
        try db.reopenTask(id: task.id, now: Fixtures.instant("2026-11-09T17:01:00Z"))
        stored = try #require(try db.task(id: task.id))
        #expect(stored.completedAt == nil && stored.completedMinutes == 0)
        #expect(stored.recurrence == rule && stored.recurrenceSeriesId == "series" && stored.recurrenceDate == "2026-11-09")
        pending = try db.pendingWrites()
        #expect(pending.count == 1)
        #expect(pending.first?.op == .patch)
        let reopenedWrite = try queuedBody(db)
        #expect(Set(reopenedWrite.keys) == ["completedAt", "completedMinutes"])
        #expect(reopenedWrite["completedAt"] is NSNull)
        #expect(reopenedWrite["completedMinutes"] as? Int == 0)
        #expect(stored.recurrenceRevision == "revision-1")

        // An older pull cannot strip metadata while this occurrence has a pending write.
        try db.apply(SyncResponse(cursor: "c2", tasks: [Fixtures.task(id: task.id)]))
        #expect(try db.task(id: task.id) == stored)
    }

    @Test func disablingQueuesExplicitNullWithoutWritingReadOnlyMetadata() throws {
        let db = try AppDatabase.inMemory()
        var task = occurrence("t1")
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.recurrence = nil
        try db.saveTask(task, now: Fixtures.t0)
        let body = try #require(try db.pendingWrites().first?.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(try db.pendingWrites().first?.op == .patch)
        #expect(Set(object.keys) == ["recurrence", "expectedRecurrenceRevision"])
        #expect(object["recurrence"] is NSNull)
        #expect(object["expectedRecurrenceRevision"] as? String == "revision-1")
        #expect(object["recurrenceSeriesId"] == nil && object["recurrenceDate"] == nil)
        #expect(object["recurrenceRevision"] == nil)
        #expect(try db.task(id: task.id)?.recurrence == nil)
        // Membership is reconciled from the server response, not invented by the editor.
        #expect(try db.task(id: task.id)?.recurrenceSeriesId == "series")
        #expect(try db.task(id: task.id)?.recurrenceDate == "2026-11-09")
    }

    @Test(arguments: [false, true])
    func saveTaskCompletionOrUndoOnlyDiffsCompletionAtSQLitePrecision(_ undo: Bool) throws {
        let db = try AppDatabase.inMemory()
        var task = occurrence("t1")
        // Editor snapshots retain sub-millisecond precision; SQLite rounds it on persistence.
        let instant = Fixtures.t0.addingTimeInterval(0.1234)
        task.dueAt = instant
        task.startAt = instant.addingTimeInterval(-3600)
        task.pinnedStart = instant.addingTimeInterval(-1800)
        task.completedAt = undo ? instant : nil
        task.completedMinutes = undo ? task.durationMinutes : 0
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.completedAt = undo ? nil : instant
        task.completedMinutes = undo ? 0 : task.durationMinutes
        // A stale editor's read-only metadata is not a local or remote write either.
        task.recurrenceSeriesId = "cached-series"
        task.recurrenceDate = "2026-11-01"
        task.recurrenceRevision = "cached-revision"
        try db.saveTask(task, now: Fixtures.t0)
        let body = try queuedBody(db)
        #expect(Set(body.keys) == ["completedAt", "completedMinutes"])
        #expect(body["completedMinutes"] as? Int == (undo ? 0 : task.durationMinutes))
        if undo { #expect(body["completedAt"] is NSNull) }
        let stored = try #require(try db.task(id: task.id))
        #expect(stored.recurrenceSeriesId == "series" && stored.recurrenceDate == "2026-11-09")
        #expect(stored.recurrenceRevision == "revision-1")
        #expect(try db.pendingWrites().first?.op == .patch)
    }

    @Test func unchangedSnapshotDoesNotQueueSpuriousTimingOrMetadataWrites() throws {
        let db = try AppDatabase.inMemory()
        var task = occurrence("t1")
        task.dueAt = Fixtures.t0.addingTimeInterval(0.9876)
        task.startAt = Fixtures.t0.addingTimeInterval(0.1234)
        task.pinnedStart = Fixtures.t0.addingTimeInterval(0.2345)
        task.completedAt = Fixtures.t0.addingTimeInterval(0.3456)
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        let stored = try db.task(id: task.id)
        task.recurrenceRevision = "not-user-editable"
        try db.saveTask(task, now: Fixtures.t0.addingTimeInterval(1))
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.task(id: task.id) == stored)
    }

    @Test func clearingNullableUserFieldsQueuesExplicitNullsOnly() throws {
        let db = try AppDatabase.inMemory()
        var task = occurrence("t1")
        task.notes = "Notes"
        task.minChunkMinutes = 15
        task.dueAt = Fixtures.t0
        task.startAt = Fixtures.t0
        task.pinnedStart = Fixtures.t0
        task.scheduleId = "work"
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.notes = nil
        task.minChunkMinutes = nil
        task.dueAt = nil
        task.startAt = nil
        task.pinnedStart = nil
        task.scheduleId = nil
        task.recurrence = nil
        try db.saveTask(task, now: Fixtures.t0)
        let body = try queuedBody(db)
        let cleared: Set<String> = ["notes", "minChunkMinutes", "dueAt", "startAt", "pinnedStart", "scheduleId", "recurrence"]
        #expect(Set(body.keys) == cleared.union(["expectedRecurrenceRevision"]))
        for key in cleared { #expect(body[key] is NSNull, "explicitly cleared \(key)") }
        #expect(body["expectedRecurrenceRevision"] as? String == "revision-1")
        let stored = try #require(try db.task(id: task.id))
        #expect(stored.notes == nil && stored.minChunkMinutes == nil && stored.scheduleId == nil)
        #expect(stored.dueAt == nil && stored.startAt == nil && stored.pinnedStart == nil && stored.recurrence == nil)
    }

    @Test func editingAllUserFieldsOmitsUntouchedCompletionAndServerMetadata() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "t1")
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.categoryId = "work"
        task.title = "Edited"
        task.notes = "Notes"
        task.durationMinutes = 90
        task.minChunkMinutes = 15
        task.priority = .asap
        task.deadlineType = .hard
        task.dueAt = Fixtures.t0
        task.startAt = Fixtures.t0
        task.scheduleId = "work"
        task.context = .errand
        task.pinnedStart = Fixtures.t0
        task.recurrence = rule
        try db.saveTask(task, now: Fixtures.t0)
        let body = try queuedBody(db)
        #expect(Set(body.keys) == ["categoryId", "title", "notes", "durationMinutes", "minChunkMinutes", "priority",
                                   "deadlineType", "dueAt", "startAt", "scheduleId", "context", "pinnedStart", "recurrence",
                                   "expectedRecurrenceRevision"])
        #expect(body["expectedRecurrenceRevision"] is NSNull)
        #expect(body["context"] as? String == "errand")
        #expect(body["durationMinutes"] as? Int == 90 && body["priority"] as? String == "asap")
        #expect(body["dueAt"] as? String == JSONCoding.formatInstant(Fixtures.t0))
    }

    @Test(arguments: [false, true], [false, true])
    func editsCompletionAndUndoCoalesceWithOriginalBaseline(_ completionFirst: Bool, _ nilBaseline: Bool) throws {
        let db = try AppDatabase.inMemory()
        var task = occurrence("t1")
        if nilBaseline {
            task.recurrence = nil
            task.recurrenceRevision = nil
            task.recurrenceSeriesId = nil
            task.recurrenceDate = nil
        }
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        if completionFirst { try db.completeTask(id: task.id, at: Fixtures.t0) }
        task = try #require(try db.task(id: task.id))
        task.title = "Edited"
        task.recurrence = rule
        task.recurrence?.interval = 3
        try db.saveTask(task, now: Fixtures.t0)
        let firstEdit = try #require(try db.pendingWrites().first)
        try db.saveTask(Fixtures.task(id: "another"), now: Fixtures.t0)
        if !completionFirst { try db.completeTask(id: task.id, at: Fixtures.t0) }
        task = try #require(try db.task(id: task.id))
        task.notes = "Later edit"
        task.recurrenceRevision = "different-later-baseline"
        try db.saveTask(task, now: Fixtures.t0)
        // macOS completion undo uses saveTask, not reopenTask.
        task = try #require(try db.task(id: task.id))
        task.completedAt = nil
        task.completedMinutes = 0
        try db.saveTask(task, now: Fixtures.t0)
        let writes = try db.pendingWrites()
        #expect(writes.map(\.entityId) == ["another", "t1"], "coalescing keeps re-queue ordering")
        #expect(try #require(writes.last?.seq) > #require(firstEdit.seq))
        let data = try #require(writes.last?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(writes.last?.op == .patch)
        #expect(Set(body.keys) == ["title", "notes", "recurrence", "expectedRecurrenceRevision", "completedAt", "completedMinutes"])
        #expect(body["title"] as? String == "Edited" && body["notes"] as? String == "Later edit")
        #expect(body["completedAt"] is NSNull && body["completedMinutes"] as? Int == 0)
        if nilBaseline {
            #expect(body["expectedRecurrenceRevision"] is NSNull)
        } else {
            #expect(body["expectedRecurrenceRevision"] as? String == "revision-1")
        }
        #expect((body["recurrence"] as? [String: Any])?["interval"] as? Int == 3)
        #expect(try db.task(id: task.id)?.isOpen == true)
    }

    @Test func creationThenEditsCompletionAndUndoStaysFullPut() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "new")
        task.recurrence = rule
        task.notes = "Clear me"
        task.dueAt = Fixtures.t0
        try db.saveTask(task, now: Fixtures.t0)
        try db.completeTask(id: task.id, at: Fixtures.t0)
        var body = try queuedBody(db)
        #expect(body["completedAt"] as? String == JSONCoding.formatInstant(Fixtures.t0))
        #expect(body["title"] as? String == "new" && body["durationMinutes"] as? Int == 60)
        #expect(try db.pendingWrites().first?.op == .put)
        task = try #require(try db.task(id: task.id))
        task.title = "Edited new task"
        task.notes = nil
        task.dueAt = nil
        task.recurrenceRevision = "must-not-replace-creation-baseline"
        try db.saveTask(task, now: Fixtures.t0)
        try db.reopenTask(id: task.id, now: Fixtures.t0)
        body = try queuedBody(db)
        #expect(try db.pendingWrites().count == 1)
        #expect(try db.pendingWrites().first?.op == .put)
        #expect(body["title"] as? String == "Edited new task")
        #expect(body["completedAt"] is NSNull && body["completedMinutes"] as? Int == 0)
        #expect(body["notes"] is NSNull && body["dueAt"] is NSNull)
        #expect(body["expectedRecurrenceRevision"] is NSNull)
        let data = try #require(try db.pendingWrites().first?.body)
        #expect(try JSONCoding.decoder.decode(TaskWrite.self, from: data).recurrence == rule)
    }

    @Test func undoingAnEditKeepsItsRevertedValueAndBaselineInPatch() throws {
        let db = try AppDatabase.inMemory()
        var task = occurrence("t1")
        let originalTitle = task.title
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.title = "Edited"
        try db.saveTask(task, now: Fixtures.t0)
        try db.completeTask(id: task.id, at: Fixtures.t0)
        task = try #require(try db.task(id: task.id))
        task.title = originalTitle
        try db.saveTask(task, now: Fixtures.t0)
        let body = try queuedBody(db)
        #expect(Set(body.keys) == ["title", "expectedRecurrenceRevision", "completedAt", "completedMinutes"])
        #expect(body["title"] as? String == originalTitle)
        #expect(body["expectedRecurrenceRevision"] as? String == "revision-1")
        #expect(try db.task(id: task.id)?.completedAt == Fixtures.t0)
    }

    @Test func staleEditorUsesItsOwnBaselineWithoutChangingStoredRevision() throws {
        let db = try AppDatabase.inMemory()
        var current = occurrence("t1")
        current.recurrenceRevision = "revision-2"
        try db.apply(SyncResponse(cursor: "c", tasks: [current]))
        var draft = current
        draft.title = "Stale edit"
        draft.recurrenceRevision = "revision-1"
        try db.saveTask(draft, now: Fixtures.t0)
        let body = try queuedBody(db)
        #expect(Set(body.keys) == ["title", "expectedRecurrenceRevision"])
        #expect(body["expectedRecurrenceRevision"] as? String == "revision-1")
        #expect(try db.task(id: draft.id)?.recurrenceRevision == "revision-2")
    }

    @Test(arguments: [false, true])
    func completionAndReopenSyncOnlyProgressAndAcceptLatestServerTemplate(_ reopening: Bool) async throws {
        let db = try AppDatabase.inMemory()
        var cached = occurrence("t1")
        if reopening {
            cached.completedAt = Fixtures.t0
            cached.completedMinutes = cached.durationMinutes
        }
        try db.apply(SyncResponse(cursor: "before", tasks: [cached]))
        if reopening {
            try db.reopenTask(id: cached.id, now: Fixtures.t0)
        } else {
            try db.completeTask(id: cached.id, at: Fixtures.t0)
        }
        var latest = try #require(try db.task(id: cached.id))
        latest.title = "Changed on another device"
        latest.recurrence?.interval = 4
        latest.durationMinutes = 90
        latest.recurrenceRevision = "revision-2"
        let scheduling = SchedulingResult(placements: [Fixtures.piece(
            taskId: cached.id, start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z")])
        let transport = FakeTransport([.ok(try Fixtures.putResponse("task", latest, scheduling: scheduling))])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 1)
        let request = try #require(transport.requests.first)
        #expect(request.method == "PATCH" && request.path == "/api/tasks/t1")
        let data = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["completedAt", "completedMinutes"])
        if reopening { #expect(body["completedAt"] is NSNull) }
        #expect(try db.task(id: cached.id) == latest)
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.placements(in: Fixtures.allTime).map(\.taskId) == [cached.id])
    }

    @Test(arguments: [404, 409])
    func rejectedTaskPatchReconcilesTombstoneOrLatestRevisionAndContinues(_ status: Int) async throws {
        let db = try AppDatabase.inMemory()
        var task = occurrence("t1")
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.recurrence?.interval = 5
        try db.saveTask(task, now: Fixtures.t0)
        try db.saveTask(Fixtures.task(id: "later"), now: Fixtures.t0)
        var latest = occurrence("t1")
        latest.title = "Server copy"
        latest.recurrenceRevision = "revision-2"
        if status == 404 { latest.deletedAt = Fixtures.t0 }
        let transport = FakeTransport([
            .error(status, status == 409 ? "recurrence changed" : "task is deleted"),
            try .ok(latest),
            .ok(try Fixtures.putResponse("task", Fixtures.task(id: "later"))),
        ])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 1)
        #expect(transport.requests.map(\.method) == ["PATCH", "GET", "PUT"])
        #expect(try db.task(id: task.id) == (status == 404 ? nil : latest))
        #expect(try db.pendingWrites().isEmpty)
        let rejected = await client.lastRejectedWrites
        #expect(rejected.first?.status == status && rejected.first?.write.op == .patch)
        let sent = try #require(rejected.first?.write.body)
        let body = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["expectedRecurrenceRevision"] as? String == "revision-1")
    }

    @Test(arguments: [false, true])
    func deletionUndoStillUsesPutAndAcceptsOneOffRestore(_ pushedDelete: Bool) async throws {
        let db = try AppDatabase.inMemory()
        let task = occurrence("t1")
        try db.apply(SyncResponse(cursor: "before", tasks: [task]))
        try db.deleteTask(id: task.id, now: Fixtures.t0)
        if pushedDelete {
            let write = try #require(try db.pendingWrites().first)
            try db.completePendingWrite(write, record: nil as TaskItem?, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
            #expect(try db.task(id: task.id) == nil)
        }
        try db.saveTask(task, now: Fixtures.t0)
        try db.completeTask(id: task.id, at: Fixtures.t0)
        try db.reopenTask(id: task.id, now: Fixtures.t0)
        #expect(try db.pendingWrites().count == 1)
        #expect(try db.pendingWrites().first?.op == .put)
        let body = try queuedBody(db)
        #expect(body["recurrence"] is NSNull, "undo explicitly restores a one-off, not the cached stopped rule")
        #expect(body["expectedRecurrenceRevision"] as? String == "revision-1")
        #expect(try db.task(id: task.id)?.recurrence == nil)
        var restored = task
        restored.recurrence = nil
        restored.recurrenceSeriesId = nil
        restored.recurrenceDate = nil
        restored.recurrenceRevision = "restored-revision"
        let transport = FakeTransport([.ok(try Fixtures.putResponse("task", restored))])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 1)
        #expect(transport.requests.first?.method == "PUT")
        #expect(try db.task(id: task.id) == restored, "the server supplies the detached one-off's fresh revision")
    }

    @Test(arguments: [false, true])
    func retryRetainsPatchIntentAndBaselineButNeverReplacesNewerQueuedEdit(_ newerEdit: Bool) async throws {
        let db = try AppDatabase.inMemory()
        var task = occurrence("t1")
        try db.apply(SyncResponse(cursor: "before", tasks: [task]))
        task.recurrence?.interval = 5
        try db.saveTask(task, now: Fixtures.t0)
        let original = try #require(try db.pendingWrites().first)
        var latest = occurrence("t1")
        latest.recurrenceRevision = "revision-2"
        let transport = FakeTransport([.error(409, "recurrence changed"), try .ok(latest)])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 0)
        if newerEdit {
            latest.notes = "New intent after rejection"
            try db.saveTask(latest, now: Fixtures.t0)
        }
        let beforeRetry = try db.pendingWrites()
        try db.requeue(original, now: Fixtures.t0)
        let pending = try db.pendingWrites()
        #expect(pending.count == 1 && pending.first?.op == .patch)
        if newerEdit {
            #expect(pending == beforeRetry)
        } else {
            #expect(pending.first?.body == original.body, "retry cannot widen the patch or rebase a stale edit")
            #expect(pending.first?.seq != original.seq)
        }
        #expect(try db.task(id: latest.id) == latest)
        let body = try queuedBody(db)
        #expect(Set(body.keys) == [newerEdit ? "notes" : "recurrence", "expectedRecurrenceRevision"])
        #expect(body["expectedRecurrenceRevision"] as? String == (newerEdit ? "revision-2" : "revision-1"))
    }

    @Test func syncEchoAndPullPreserveSeriesAndDistinctOccurrences() async throws {
        let db = try AppDatabase.inMemory()
        var local = occurrence("t1")
        local.recurrenceSeriesId = nil
        local.recurrenceDate = nil
        local.recurrenceRevision = nil
        try db.saveTask(local, now: Fixtures.t0)
        let server = occurrence("t1")
        let future = occurrence("t2", date: "2026-11-11")
        let transport = FakeTransport([
            .ok(try Fixtures.putResponse("task", server)),
            try .ok(SyncResponse(cursor: "c1", tasks: [server, future])),
        ])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.sync() == 1)
        #expect(try db.task(id: server.id) == server)
        #expect(try db.task(id: future.id) == future)
        #expect(try db.pendingWrites().isEmpty)
        let request = try #require(transport.requests.first)
        #expect(request.method == "PUT" && request.path == "/api/tasks/t1")
        #expect(try JSONCoding.decoder.decode(TaskWrite.self, from: try #require(request.body)).recurrence == rule)

        try db.completeTask(id: server.id, at: Fixtures.t0)
        let completed = try #require(try db.task(id: server.id))
        let completingTransport = FakeTransport([
            .ok(try Fixtures.putResponse("task", completed)),
            try .ok(SyncResponse(cursor: "c2", tasks: [completed, future])),
        ])
        let completingClient = SyncClient(database: db, config: config, transport: completingTransport)
        #expect(try await completingClient.sync() == 1)
        #expect(try db.task(id: server.id)?.recurrenceDate == "2026-11-09")
        #expect(try db.task(id: server.id)?.recurrence == rule)
        #expect(try db.task(id: server.id)?.recurrenceRevision == "revision-1")
        #expect(try db.task(id: future.id)?.completedAt == nil)
        #expect(try db.openTasks().map(\.id) == [future.id])
        #expect(completingTransport.requests.first?.method == "PATCH")
        let sent = try #require(completingTransport.requests.first?.body)
        #expect(Set(try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any]).keys) == ["completedAt", "completedMinutes"])
    }

    @Test(arguments: [false, true])
    func stoppingSeriesAppliesServerTombstonesAndKeepsCompletedHistory(_ deleting: Bool) async throws {
        let db = try AppDatabase.inMemory()
        var selected = occurrence("selected")
        var future = occurrence("future", date: "2026-11-11")
        var history = occurrence("history", date: "2026-10-26")
        history.completedAt = Fixtures.t0
        history.completedMinutes = history.durationMinutes
        try db.apply(SyncResponse(cursor: "before", tasks: [selected, future, history]))
        if deleting {
            try db.deleteTask(id: selected.id, now: Fixtures.t0)
            selected.deletedAt = Fixtures.t0
        } else {
            selected.recurrence = nil
            try db.saveTask(selected, now: Fixtures.t0)
            selected.recurrenceSeriesId = nil
            selected.recurrenceDate = nil
        }
        future.deletedAt = Fixtures.t0
        let accepted = deleting ? try Fixtures.deleteResponse() : try Fixtures.putResponse("task", selected)
        let transport = FakeTransport([
            .ok(accepted),
            try .ok(SyncResponse(cursor: "after", tasks: [selected, future])),
        ])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.sync() == 1)
        #expect(try db.task(id: future.id) == nil)
        #expect(try db.task(id: history.id) == history)
        #expect(try db.pendingWrites().isEmpty)
        if deleting {
            #expect(transport.requests.first?.method == "DELETE")
            #expect(try db.task(id: selected.id) == nil)
        } else {
            let request = try #require(transport.requests.first)
            let body = try #require(request.body)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(request.method == "PATCH" && object["recurrence"] is NSNull)
            #expect(try db.task(id: selected.id) == selected)
        }
    }
}
