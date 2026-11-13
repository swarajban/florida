import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloridaKit

private enum RecoveryWrite: CaseIterable, Sendable {
    case taskPut, projectPut, taskPatch, projectPatch

    var isTask: Bool { self == .taskPut || self == .taskPatch }
}

private enum RecoveryCategoryCopy: CaseIterable, Sendable {
    case live, missing, tombstoned
}

private actor CategoryRecoveryTransport: HTTPTransport {
    let copy: RecoveryCategoryCopy
    let rejectDelete: Bool
    let failRecovery: Bool
    let unavailable: Bool
    var requests: [RecordedRequest] = []

    init(copy: RecoveryCategoryCopy = .live, rejectDelete: Bool = false, failRecovery: Bool = false, unavailable: Bool = false) {
        self.copy = copy
        self.rejectDelete = rejectDelete
        self.failRecovery = failRecovery
        self.unavailable = unavailable
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        requests.append(RecordedRequest(method: method, path: url.path, query: [:], headers: [:], body: request.httpBody))
        var status = 200
        let body: Data
        if url.path == "/api/categories/work", method == "GET" {
            if failRecovery { throw NetworkDown() }
            if unavailable {
                status = 404
                body = Data("not found".utf8)
            } else if copy == .missing {
                status = 404
                body = Data(#"{"error":"category not found"}"#.utf8)
            } else {
                var category = Fixtures.category(id: "work")
                if copy == .tombstoned { category.deletedAt = Fixtures.t0 }
                body = try JSONCoding.encoder.encode(category)
            }
        } else if url.path == "/api/categories/work", method == "DELETE" {
            status = rejectDelete ? 409 : 200
            body = rejectDelete ? Data(#"{"error":"category changed"}"#.utf8) : try Fixtures.deleteResponse()
        } else if url.path == "/api/categories/work", method == "PUT" {
            body = try Fixtures.putResponse("category", Fixtures.category(id: "work"))
        } else if url.path == "/api/sync" {
            body = try JSONCoding.encoder.encode(SyncResponse(cursor: "after-recovery"))
        } else {
            let data = try #require(request.httpBody)
            let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if url.path == "/api/tasks/task" {
                var task = Fixtures.task(id: "task", categoryId: fields["categoryId"] as? String ?? "work")
                task.title = fields["title"] as? String ?? task.title
                task.notes = fields["notes"] as? String
                body = try Fixtures.putResponse("task", task)
            } else {
                let project = Project(id: "project", name: fields["name"] as? String ?? "Project",
                    categoryId: fields["categoryId"] as? String, notes: fields["notes"] as? String,
                    createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
                body = try Fixtures.putResponse("project", project)
            }
        }
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct CategoryRecoveryOrderingTests {
    let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")

    private func prepare(_ kind: RecoveryWrite, discarded: Bool, laterFiling: Bool = false) async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "task", categoryId: "work")
        var project = Project(id: "project", name: "Project", categoryId: "work", createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        var baseline = task
        if kind == .taskPatch { baseline.categoryId = TaskCategory.inboxId }
        try db.apply(SyncResponse(cursor: "c", categories: [Fixtures.category(id: "work"), Fixtures.category(id: "other")],
            tasks: kind == .taskPut ? [] : [baseline], projects: kind == .projectPut ? [] : [project]))
        if kind.isTask {
            try db.saveTask(task)
        } else if kind == .projectPut {
            try db.saveProject(project)
        } else {
            let body = try JSONSerialization.data(withJSONObject: ["categoryId": "work", "name": "Queued project"])
            try db.requeue(PendingWrite(entity: .project, entityId: project.id, op: .patch, body: body, createdAt: Fixtures.t0))
        }
        try db.deleteCategory(id: "work")
        let deletion = try #require(try db.pendingWrites().first { $0.entity == .category })
        if kind.isTask {
            task = try #require(try db.task(id: task.id))
            task.title = "Latest task title"
            task.notes = "Latest task notes"
            if laterFiling { task.categoryId = "other" }
            try db.saveTask(task)
        } else if kind == .projectPut || laterFiling {
            project = try #require(try db.project(id: project.id))
            project.name = "Latest project title"
            project.notes = "Latest project notes"
            if laterFiling { project.categoryId = "other" }
            try db.saveProject(project)
        }
        if discarded {
            let failed = SyncClient(database: db, config: config, transport: FakeTransport([.failure(NetworkDown())]))
            await #expect(throws: SyncError.self) { try await failed.discard(deletion) }
        }
        return try AppDatabase(writer: db.writer)
    }

    @Test(arguments: RecoveryWrite.allCases, RecoveryCategoryCopy.allCases)
    private func syncRecoversDiscardedCategoryBeforeCapturingDependentWrites(_ kind: RecoveryWrite, _ copy: RecoveryCategoryCopy) async throws {
        try await verifyRecovery(kind, copy: copy, sync: true, laterFiling: false)
    }

    @Test(arguments: RecoveryWrite.allCases, RecoveryCategoryCopy.allCases)
    private func publicPushRecoversDiscardedCategoryAfterRestart(_ kind: RecoveryWrite, _ copy: RecoveryCategoryCopy) async throws {
        try await verifyRecovery(kind, copy: copy, sync: false, laterFiling: false)
    }

    @Test(arguments: RecoveryWrite.allCases, RecoveryCategoryCopy.allCases)
    private func recoveryPreservesLaterDeliberateFiling(_ kind: RecoveryWrite, _ copy: RecoveryCategoryCopy) async throws {
        try await verifyRecovery(kind, copy: copy, sync: true, laterFiling: true)
    }

    private func verifyRecovery(_ kind: RecoveryWrite, copy: RecoveryCategoryCopy, sync: Bool, laterFiling: Bool) async throws {
        let db = try await prepare(kind, discarded: true, laterFiling: laterFiling)
        let transport = CategoryRecoveryTransport(copy: copy)
        let client = SyncClient(database: db, config: config, transport: transport)
        let count = try await (sync ? client.sync() : client.push())
        #expect(count == 1)
        let requests = await transport.requests
        #expect(requests.first?.method == "GET" && requests.first?.path == "/api/categories/work")
        let request = try #require(requests.first { $0.method == "PUT" || $0.method == "PATCH" })
        let body = try #require(request.body)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let expected = laterFiling ? "other" : copy == .live ? "work" : kind.isTask ? TaskCategory.inboxId : nil
        #expect(fields["categoryId"] as? String == expected)
        if kind.isTask {
            #expect(try db.task(id: "task")?.categoryId == expected)
            #expect(fields["title"] as? String == "Latest task title")
            #expect(fields["notes"] as? String == "Latest task notes")
        } else {
            #expect(try db.project(id: "project")?.categoryId == expected)
        }
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test(arguments: RecoveryWrite.allCases, [false, true])
    private func failedRecoveryNeverTransmitsTheDependentQueue(_ kind: RecoveryWrite, _ sync: Bool) async throws {
        let db = try await prepare(kind, discarded: true)
        let before = try db.pendingWrites()
        let transport = CategoryRecoveryTransport(failRecovery: true)
        for _ in 0..<2 {
            let reopened = try AppDatabase(writer: db.writer)
            let client = SyncClient(database: reopened, config: config, transport: transport)
            await #expect(throws: SyncError.self) { _ = try await (sync ? client.sync() : client.push()) }
            #expect(try reopened.pendingWrites() == before)
        }
        #expect(await transport.requests.allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: RecoveryWrite.allCases)
    private func unavailableRecoveryRouteKeepsDependentChangesQueued(_ kind: RecoveryWrite) async throws {
        let db = try await prepare(kind, discarded: true)
        let before = try db.pendingWrites()
        let transport = CategoryRecoveryTransport(unavailable: true)
        let client = SyncClient(database: db, config: config, transport: transport)
        await #expect(throws: SyncError.self) { _ = try await client.push() }
        #expect(try db.pendingWrites() == before)
        #expect(await transport.requests.allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: RecoveryWrite.allCases)
    private func rejectedCategoryDeleteUsesCurrentRestoredBodiesInTheSamePush(_ kind: RecoveryWrite) async throws {
        let db = try await prepare(kind, discarded: false)
        let transport = CategoryRecoveryTransport(rejectDelete: true)
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 1)
        let requests = await transport.requests
        #expect(requests.first?.method == "DELETE" && requests.first?.path == "/api/categories/work")
        let request = try #require(requests.first { $0.method == "PUT" || $0.method == "PATCH" })
        let body = try #require(request.body)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields["categoryId"] as? String == "work")
        #expect(await client.lastRejectedWrites.count == 1)
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test(arguments: RecoveryWrite.allCases)
    private func acceptedCategorySaveResolvesRollbackBeforeDependentWrites(_ kind: RecoveryWrite) async throws {
        let db = try await prepare(kind, discarded: true)
        try db.saveCategory(Fixtures.category(id: "work"))
        let transport = CategoryRecoveryTransport()
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 2)
        let requests = await transport.requests
        #expect(requests.first?.method == "PUT" && requests.first?.path == "/api/categories/work")
        #expect(!requests.contains { $0.method == "GET" && $0.path == "/api/categories/work" })
        let dependent = try #require(requests.first { $0.path != "/api/categories/work" })
        let body = try #require(dependent.body)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields["categoryId"] as? String == "work")
        #expect(try db.pendingWrites().isEmpty)
    }
}
