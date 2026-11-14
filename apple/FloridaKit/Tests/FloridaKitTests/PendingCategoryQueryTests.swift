import Foundation
import GRDB
import Testing
@testable import FloridaKit

private final class QueueSQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ sql: String) { lock.withLock { storage.append(sql) } }
    var statements: [String] { lock.withLock { storage } }
}

@Suite struct PendingCategoryQueryTests {
    @Test func dependentChecksDoNotMaterializeTheWholePendingQueue() async throws {
        let queue = try DatabaseQueue()
        let db = try AppDatabase(writer: queue)
        let tasks = (0..<24).map { index in
            var task = Fixtures.task(id: "task-\(index)")
            task.notes = String(repeating: "n", count: 1024)
            return task
        }
        for task in tasks { try db.saveTask(task) }
        let trace = QueueSQLTrace()
        try await queue.write { db in
            db.trace { event in
                if case .statement(let statement) = event { trace.append(statement.sql) }
            }
        }
        let transport = FakeTransport(try tasks.map { .ok(try Fixtures.putResponse("task", $0)) })
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == tasks.count)
        try await queue.write { $0.trace(nil) }
        let sql = trace.statements.map { $0.replacingOccurrences(of: "\"", with: "").lowercased() }
        let wholeQueueReads = sql.filter { $0.hasPrefix("select * from pendingwrite order by") }
        let existenceReads = sql.filter { $0.contains("select exists") && $0.contains("pendingwrite") }
        #expect(wholeQueueReads.count == 1)
        #expect(existenceReads.count == tasks.count)
        #expect(try db.pendingWrites().isEmpty)
    }
}
