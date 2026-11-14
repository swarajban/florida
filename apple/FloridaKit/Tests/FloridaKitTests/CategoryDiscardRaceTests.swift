import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloridaKit

private actor GatedCategoryTransport: HTTPTransport {
    let category: TaskCategory
    var deleteFinished = false
    var fetchedBeforeDeleteFinished = false
    var deletion: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?

    init(category: TaskCategory) { self.category = category }

    func waitUntilStarted() async {
        if deletion != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func releaseDelete() {
        deletion?.resume()
        deletion = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if request.httpMethod == "DELETE" {
            await withCheckedContinuation { continuation in
                deletion = continuation
                started?.resume()
                started = nil
            }
            deleteFinished = true
            return (try Fixtures.deleteResponse(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        fetchedBeforeDeleteFinished = !deleteFinished
        if deleteFinished {
            return (Data(#"{"error":"category not found"}"#.utf8), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (try JSONCoding.encoder.encode(category), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct CategoryDiscardRaceTests {
    @Test func discardWaitsForAnInflightCategoryDeleteBeforeReconciling() async throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let task = Fixtures.task(id: "task", categoryId: category.id)
        let project = Project(id: "project", name: "Project", categoryId: category.id, createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        try db.apply(SyncResponse(cursor: "c", categories: [category], tasks: [task], projects: [project]))
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first)
        let transport = GatedCategoryTransport(category: category)
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        let push = Task { try await client.push() }
        await transport.waitUntilStarted()
        let discard = Task { try await client.discard(deletion) }
        try await Task.sleep(for: .milliseconds(100))
        await transport.releaseDelete()
        #expect(try await push.value == 1)
        try await discard.value
        #expect(await transport.fetchedBeforeDeleteFinished == false)
        #expect(try db.categories().isEmpty)
        #expect(try db.task(id: task.id)?.categoryId == TaskCategory.inboxId)
        #expect(try db.project(id: project.id)?.categoryId == nil)
        #expect(try db.pendingWrites().isEmpty)
    }
}
