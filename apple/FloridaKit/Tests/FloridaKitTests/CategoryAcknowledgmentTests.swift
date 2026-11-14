import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import FloridaKit

private enum CategoryAckScenario: CaseIterable, Sendable {
    case acceptedPutThenPut, rejectedDeleteThenPut, rejectedPutThenPut, acceptedPutThenDelete, acceptedDeleteThenPut

    var firstDeletes: Bool { self == .rejectedDeleteThenPut || self == .acceptedDeleteThenPut }
    var firstRejects: Bool { self == .rejectedDeleteThenPut || self == .rejectedPutThenPut }
    var newerDeletes: Bool { self == .acceptedPutThenDelete }
}

private enum CategoryAckCopy: CaseIterable, Sendable {
    case live, missing, tombstoned
}

private actor GatedCategoryAckTransport: HTTPTransport {
    let scenario: CategoryAckScenario
    let copy: CategoryAckCopy
    let rejectNewerDelete: Bool
    var category: TaskCategory?
    var task: TaskItem?
    var project: Project?
    var requests: [RecordedRequest] = []
    var firstStarted = false
    var gate: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?

    init(scenario: CategoryAckScenario, copy: CategoryAckCopy, rejectNewerDelete: Bool) {
        self.scenario = scenario
        self.copy = copy
        self.rejectNewerDelete = rejectNewerDelete
        category = copy == .live ? Fixtures.category(id: "work") : nil
    }

    func waitUntilStarted() async {
        if gate != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func releaseFirst() {
        gate?.resume()
        gate = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        requests.append(RecordedRequest(method: method, path: url.path, query: [:], headers: [:], body: request.httpBody))
        let isFirst = url.path == "/api/categories/work" && method != "GET" && !firstStarted
        if isFirst {
            firstStarted = true
            await withCheckedContinuation { continuation in
                gate = continuation
                started?.resume()
                started = nil
            }
        }
        var status = 200
        let body: Data
        if url.path == "/api/categories/work", method == "GET" {
            if let category {
                body = try JSONCoding.encoder.encode(category)
            } else if copy == .tombstoned {
                var tombstone = Fixtures.category(id: "work")
                tombstone.deletedAt = Fixtures.t0
                body = try JSONCoding.encoder.encode(tombstone)
            } else {
                status = 404
                body = Data(#"{"error":"category not found"}"#.utf8)
            }
        } else if url.path == "/api/categories/work", (isFirst && scenario.firstRejects) || (!isFirst && method == "DELETE" && rejectNewerDelete) {
            status = 409
            body = Data(#"{"error":"category changed"}"#.utf8)
        } else if url.path == "/api/categories/work", method == "DELETE" {
            category = nil
            if task?.categoryId == "work" { task?.categoryId = TaskCategory.inboxId }
            if project?.categoryId == "work" { project?.categoryId = nil }
            body = try Fixtures.deleteResponse()
        } else {
            let data = try #require(request.httpBody)
            let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if url.path == "/api/categories/work" {
                var value = Fixtures.category(id: "work")
                value.name = isFirst ? "Accepted A" : fields["name"] as? String ?? "Work"
                value.color = fields["color"] as? String
                value.sortOrder = fields["sortOrder"] as? Int ?? 0
                category = value
                body = try Fixtures.putResponse("category", value)
            } else if url.path == "/api/tasks/task" {
                var value = Fixtures.task(id: "task", categoryId: fields["categoryId"] as? String ?? "work")
                value.title = fields["title"] as? String ?? value.title
                value.notes = fields["notes"] as? String
                task = value
                body = try Fixtures.putResponse("task", value)
            } else {
                let value = Project(id: "project", name: fields["name"] as? String ?? "Project",
                    categoryId: fields["categoryId"] as? String, notes: fields["notes"] as? String,
                    createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
                project = value
                body = try Fixtures.putResponse("project", value)
            }
        }
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct CategoryAcknowledgmentTests {
    @Test(arguments: CategoryAckScenario.allCases, [false, true])
    private func supersededActionsSettleReferencesWithoutClobberingNewerCategory(_ scenario: CategoryAckScenario, _ laterFiling: Bool) async throws {
        try await verify(scenario, laterFiling: laterFiling)
    }

    @Test(arguments: [CategoryAckScenario.rejectedDeleteThenPut, .rejectedPutThenPut], [CategoryAckCopy.missing, .tombstoned])
    private func rejectedActionsWithConfirmedDeletionKeepSafeReferences(_ scenario: CategoryAckScenario, _ copy: CategoryAckCopy) async throws {
        try await verify(scenario, copy: copy)
    }

    @Test(arguments: [false, true])
    private func newerDeleteCanStillRollBackAfterTheOlderPutIsAcknowledged(_ laterFiling: Bool) async throws {
        try await verify(.acceptedPutThenDelete, laterFiling: laterFiling, rejectNewerDelete: true)
    }

    private func verify(_ scenario: CategoryAckScenario, copy: CategoryAckCopy = .live, laterFiling: Bool = false, rejectNewerDelete: Bool = false) async throws {
        let db = try AppDatabase.inMemory()
        var category = Fixtures.category(id: "work")
        var task = Fixtures.task(id: "task", categoryId: category.id)
        var project = Project(id: "project", name: "Project", categoryId: category.id, createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        try db.apply(SyncResponse(cursor: "c", categories: [category, Fixtures.category(id: "other")]))
        try db.saveTask(task)
        try db.saveProject(project)
        try db.deleteCategory(id: category.id)
        if !scenario.firstDeletes {
            category.name = "Queued A"
            category.color = "red"
            try db.saveCategory(category)
        }
        task = try #require(try db.task(id: task.id))
        project = try #require(try db.project(id: project.id))
        task.title = "Latest task title"
        task.notes = "Latest task notes"
        project.name = "Latest project name"
        project.notes = "Latest project notes"
        try db.saveTask(task)
        try db.saveProject(project)
        let transport = GatedCategoryAckTransport(scenario: scenario, copy: copy, rejectNewerDelete: rejectNewerDelete)
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        let first = Task { try await client.push() }
        await transport.waitUntilStarted()
        if scenario.newerDeletes {
            try db.deleteCategory(id: category.id)
        } else {
            category.name = "Queued B"
            category.color = "blue"
            category.sortOrder = 99
            try db.saveCategory(category)
        }
        if laterFiling {
            task.categoryId = "other"
            project.categoryId = "other"
            try db.saveTask(task)
            try db.saveProject(project)
        }
        let newer = try #require(try db.pendingWrites().first { $0.entity == .category })
        let newerCategory = try await db.writer.read { try TaskCategory.fetchOne($0, id: "work") }
        await transport.releaseFirst()
        #expect(try await first.value == (scenario.firstRejects ? 0 : 1))
        #expect(try db.pendingWrites().first { $0.entity == .category } == newer)
        let afterFirstCategory = try await db.writer.read { try TaskCategory.fetchOne($0, id: "work") }
        #expect(afterFirstCategory == newerCategory)
        #expect(await transport.requests.allSatisfy { $0.path == "/api/categories/work" })
        let confirmedDeleted = scenario == .acceptedDeleteThenPut || (scenario.firstRejects && copy != .live)
        let interimTask = laterFiling ? "other" : scenario.newerDeletes || confirmedDeleted ? TaskCategory.inboxId : "work"
        let interimProject: String? = laterFiling ? "other" : scenario.newerDeletes || confirmedDeleted ? nil : "work"
        #expect(try db.task(id: task.id)?.categoryId == interimTask)
        #expect(try db.project(id: project.id)?.categoryId == interimProject)
        #expect(try db.task(id: task.id)?.notes == task.notes)
        #expect(try db.project(id: project.id)?.notes == project.notes)
        #expect(try await client.push() == (rejectNewerDelete ? 2 : 3))
        let finalDeleted = confirmedDeleted || (scenario.newerDeletes && !rejectNewerDelete)
        let finalTask = laterFiling ? "other" : finalDeleted ? TaskCategory.inboxId : "work"
        let finalProject: String? = laterFiling ? "other" : finalDeleted ? nil : "work"
        let serverTask = try #require(await transport.task)
        let serverProject = try #require(await transport.project)
        #expect(serverTask.categoryId == finalTask)
        #expect(serverProject.categoryId == finalProject)
        #expect(try db.task(id: task.id)?.categoryId == serverTask.categoryId)
        #expect(try db.project(id: project.id)?.categoryId == serverProject.categoryId)
        #expect(serverTask.title == task.title && serverTask.notes == task.notes)
        #expect(serverProject.name == project.name && serverProject.notes == project.notes)
        let serverCategory = await transport.category
        let finalCategory = try await db.writer.read { try TaskCategory.fetchOne($0, id: "work") }
        #expect(finalCategory == serverCategory)
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.categoryDeletionsNeedingRecovery().isEmpty)
    }
}
