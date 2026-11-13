import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct TaskSourceStoreTests {
    private let source = TaskSource.from(url: "https://github.com/acme/widget/pull/123")!

    private func queuedBody(_ database: AppDatabase) throws -> [String: Any] {
        let body = try #require(try database.pendingWrites().first?.body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func v8MigrationPreservesTaskAndOlderQueuedWriteAndResetsCursor() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v8-event-blocks-day")
        let olderBody = Data(#"{"title":"Keep queued edit"}"#.utf8)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO task (id, categoryId, title, durationMinutes, priority, deadlineType, completedMinutes,
                                  createdAt, updatedAt)
                VALUES ('old', 'inbox', 'Keep task', 30, 'medium', 'none', 0,
                        '2026-11-08 00:00:00.000', '2026-11-08 00:00:00.000');
                INSERT INTO syncState (key, value) VALUES ('cursor', 'old-cursor');
                INSERT INTO syncState (key, value) VALUES ('other', 'keep');
                """)
            var pending = PendingWrite(entity: .task, entityId: "old", op: .patch, body: olderBody, createdAt: Fixtures.t0)
            try pending.insert(db)
        }
        let database = try AppDatabase(writer: queue)
        let task = try #require(try database.task(id: "old"))
        #expect(task.title == "Keep task" && task.source == nil)
        #expect(try database.pendingWrites().first?.body == olderBody)
        #expect(try database.cursor() == nil)
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT value FROM syncState WHERE key = 'other'") } == "keep")
    }

    @Test func sourcePersistsAsJSONAndUnrelatedEditsDoNotRewriteIt() throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task")
        task.source = source
        try database.apply(SyncResponse(cursor: "c1", tasks: [task]))
        #expect(try database.task(id: task.id)?.source == source)
        let json = try #require(try database.writer.read {
            try String.fetchOne($0, sql: "SELECT source FROM task WHERE id = 'task'")
        })
        #expect(try JSONDecoder().decode(TaskSource.self, from: Data(json.utf8)) == source)
        task.title = "Renamed"
        try database.saveTask(task, now: Fixtures.t0)
        #expect(try queuedBody(database)["source"] == nil)
        #expect(try database.task(id: task.id)?.source == source)
        try database.apply(SyncResponse(cursor: "c2", tasks: [Fixtures.task(id: "task")]))
        #expect(try database.task(id: task.id)?.source == source)
    }

    @Test func editsAndClearsSourceInPatchesAndPendingPuts() throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task")
        try database.apply(SyncResponse(cursor: "c1", tasks: [task]))
        task.source = source
        try database.saveTask(task, now: Fixtures.t0)
        #expect(try database.pendingWrites().first?.op == .patch)
        #expect(try queuedBody(database)["source"] as? [String: String] == [
            "url": source.url, "title": source.title, "kind": source.kind.rawValue,
        ])
        task.source = nil
        try database.saveTask(task, now: Fixtures.t0)
        #expect(try queuedBody(database)["source"] is NSNull)
        #expect(try database.task(id: task.id)?.source == nil)

        let fresh = try AppDatabase.inMemory()
        task.source = source
        try fresh.saveTask(task, now: Fixtures.t0)
        #expect(try fresh.pendingWrites().first?.op == .put)
        task.source = nil
        try fresh.saveTask(task, now: Fixtures.t0)
        #expect(try fresh.pendingWrites().first?.op == .put)
        #expect(try queuedBody(fresh)["source"] is NSNull)
    }

    @Test func syncPushesSourceThenPullsAndExplicitlyClears() async throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task")
        task.source = source
        try database.saveTask(task, now: Fixtures.t0)
        var pulled = Fixtures.task(id: "pulled")
        pulled.source = TaskSource.from(url: "https://linear.app/acme/issue/ABC-12/fix")
        let transport = FakeTransport([
            .ok(try Fixtures.putResponse("task", task)),
            try .ok(SyncResponse(cursor: "c1", tasks: [pulled])),
        ])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: database, config: config, transport: transport)
        #expect(try await client.sync() == 1)
        let request = try #require(transport.requests.first)
        #expect(request.method == "PUT")
        let sent = try JSONCoding.decoder.decode(TaskWrite.self, from: try #require(request.body))
        #expect(sent.source == source)
        #expect(try database.task(id: task.id)?.source == source)
        #expect(try database.task(id: pulled.id)?.source == pulled.source)

        task.source = nil
        try database.saveTask(task, now: Fixtures.t0)
        let clearTransport = FakeTransport([
            .ok(try Fixtures.putResponse("task", task)),
            try .ok(SyncResponse(cursor: "c2")),
        ])
        let clearClient = SyncClient(database: database, config: config, transport: clearTransport)
        #expect(try await clearClient.sync() == 1)
        let clear = try #require(clearTransport.requests.first)
        #expect(clear.method == "PATCH")
        let clearBody = try #require(clear.body)
        let body = try #require(JSONSerialization.jsonObject(with: clearBody) as? [String: Any])
        #expect(body["source"] is NSNull)
        #expect(try database.task(id: task.id)?.source == nil)
    }

    @Test func syncDoesNotAddSourceToOlderQueuedWrites() async throws {
        let database = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task")
        task.source = source
        try database.apply(SyncResponse(cursor: "c1", tasks: [task]))
        let olderBody = Data(#"{"title":"Older client edit"}"#.utf8)
        let taskId = task.id
        try await database.writer.write { db in
            var pending = PendingWrite(entity: .task, entityId: taskId, op: .patch, body: olderBody, createdAt: Fixtures.t0)
            try pending.insert(db)
        }
        task.title = "Older client edit"
        let transport = FakeTransport([
            .ok(try Fixtures.putResponse("task", task)),
            try .ok(SyncResponse(cursor: "c2")),
        ])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: database, config: config, transport: transport)
        #expect(try await client.sync() == 1)
        #expect(transport.requests.first?.body == olderBody)
        #expect(try database.task(id: task.id)?.source == source)
    }
}
