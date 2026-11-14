import Foundation
import Testing
@testable import FloridaKit

@Suite struct CategoryDeletionRollbackTests {
    func project(_ id: String = "project", category: String? = "work") -> Project {
        Project(id: id, name: id, categoryId: category, createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
    }

    func fields(_ write: PendingWrite) throws -> [String: Any] {
        let body = try #require(write.body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func withoutCategory(_ write: PendingWrite) throws -> Data {
        var object = try fields(write)
        object.removeValue(forKey: "categoryId")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test(arguments: [false, true])
    func discardedOrRejectedDeleteRestoresDependentReferencesAfterReopen(_ discarded: Bool) throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let task = Fixtures.task(id: "task", categoryId: category.id)
        let project = project()
        try db.apply(SyncResponse(cursor: "c", categories: [category], tasks: [task], projects: [project]))
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first)
        let reopened = try AppDatabase(writer: db.writer)
        if discarded { try reopened.removePendingWrite(seq: #require(deletion.seq)) }
        let reconciled = try AppDatabase(writer: reopened.writer)
        try reconciled.resolveDroppedWrite(deletion, serverCopy: .live(category))
        try reconciled.apply(SyncResponse(cursor: "empty-incremental"))
        #expect(try reconciled.task(id: task.id)?.categoryId == category.id)
        #expect(try reconciled.project(id: project.id)?.categoryId == category.id)
        #expect(try reconciled.task(id: task.id)?.title == task.title)
        #expect(try reconciled.pendingWrites().isEmpty)
    }

    @Test func actualRejectedDeleteRestoresReferencesBeforeAnEmptyIncrementalPull() async throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let task = Fixtures.task(id: "task", categoryId: category.id)
        let project = project()
        try db.apply(SyncResponse(cursor: "c", categories: [category], tasks: [task], projects: [project]))
        try db.deleteCategory(id: category.id)
        let transport = FakeTransport([
            .error(409, "category changed elsewhere"),
            try .ok(category),
            try .ok(SyncResponse(cursor: "empty-incremental")),
        ])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.sync() == 0)
        #expect(await client.lastRejectedWrites.count == 1)
        #expect(transport.requests.map(\.method) == ["DELETE", "GET", "GET"])
        #expect(try db.task(id: task.id)?.categoryId == category.id)
        #expect(try db.project(id: project.id)?.categoryId == category.id)
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test(arguments: [false, true])
    func rollbackRestoresOnlyCategoryFieldsInCurrentQueuedPutAndPatch(_ creation: Bool) throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        var task = Fixtures.task(id: "task", categoryId: category.id)
        var initial = task
        initial.categoryId = TaskCategory.inboxId
        var project = project()
        try db.apply(SyncResponse(cursor: "c", categories: [category], tasks: creation ? [] : [initial], projects: [project]))
        task.title = "Original queued title"
        task.recurrenceRevision = "revision-baseline"
        try db.saveTask(task)
        try db.saveProject(project)
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first { $0.entity == .category })
        task = try #require(try db.task(id: task.id))
        task.title = "Later title"
        task.notes = "Later task notes"
        try db.saveTask(task)
        project = try #require(try db.project(id: project.id))
        project.name = "Later project title"
        project.notes = "Later project notes"
        try db.saveProject(project)
        let beforeTask = try #require(try db.pendingWrites().first { $0.entity == .task })
        let beforeProject = try #require(try db.pendingWrites().first { $0.entity == .project })
        let reopened = try AppDatabase(writer: db.writer)
        try reopened.resolveDroppedWrite(deletion, serverCopy: .live(category))
        let afterTask = try #require(try reopened.pendingWrites().first { $0.entity == .task })
        let afterProject = try #require(try reopened.pendingWrites().first { $0.entity == .project })
        #expect(afterTask.op == (creation ? .put : .patch))
        #expect(afterTask.seq == beforeTask.seq && afterProject.seq == beforeProject.seq)
        #expect(afterTask.createdAt == beforeTask.createdAt && afterProject.createdAt == beforeProject.createdAt)
        #expect(try fields(afterTask)["categoryId"] as? String == category.id)
        #expect(try fields(afterProject)["categoryId"] as? String == category.id)
        #expect(try withoutCategory(afterTask) == withoutCategory(beforeTask))
        #expect(try withoutCategory(afterProject) == withoutCategory(beforeProject))
        #expect(try reopened.task(id: task.id)?.categoryId == category.id)
        #expect(try reopened.project(id: project.id)?.categoryId == category.id)
        #expect(try reopened.task(id: task.id)?.title == task.title)
        #expect(try reopened.task(id: task.id)?.notes == task.notes)
        #expect(try reopened.project(id: project.id)?.name == project.name)
        #expect(try reopened.project(id: project.id)?.notes == project.notes)
        #expect(try reopened.pendingWrites().count == 2)
    }

    @Test func laterTitleOnlyWritesKeepPatchOmissionsAndRestoreProjectPutCategory() throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let task = Fixtures.task(id: "task", categoryId: category.id)
        let project = project()
        try db.apply(SyncResponse(cursor: "c", categories: [category], tasks: [task], projects: [project]))
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first)
        var changedTask = try #require(try db.task(id: task.id))
        changedTask.notes = "Only notes changed"
        try db.saveTask(changedTask)
        var changedProject = try #require(try db.project(id: project.id))
        changedProject.name = "Only name changed"
        try db.saveProject(changedProject)
        let beforeTask = try #require(try db.pendingWrites().first { $0.entity == .task })
        #expect(try fields(beforeTask)["categoryId"] == nil)
        try db.resolveDroppedWrite(deletion, serverCopy: .live(category))
        let afterTask = try #require(try db.pendingWrites().first { $0.entity == .task })
        let afterProject = try #require(try db.pendingWrites().first { $0.entity == .project })
        #expect(afterTask.body == beforeTask.body && afterTask.op == .patch)
        #expect(try fields(afterProject)["categoryId"] as? String == category.id)
        #expect(try db.task(id: task.id)?.categoryId == category.id)
        #expect(try db.project(id: project.id)?.categoryId == category.id)
        #expect(try db.task(id: task.id)?.notes == changedTask.notes)
        #expect(try db.project(id: project.id)?.name == changedProject.name)
    }

    @Test func projectPatchRestoresOnlyItsCurrentCategoryField() throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let project = project()
        try db.apply(SyncResponse(cursor: "c", categories: [category], projects: [project]))
        let original = try JSONSerialization.data(withJSONObject: ["categoryId": category.id, "name": "Original queued name"])
        try db.requeue(PendingWrite(entity: .project, entityId: project.id, op: .patch, body: original, createdAt: Fixtures.t0))
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first { $0.entity == .category })
        let rewritten = try #require(try db.pendingWrites().first { $0.entity == .project })
        var current = try fields(rewritten)
        #expect(current["categoryId"] is NSNull)
        current["name"] = "Newer queued name"
        current["notes"] = "Newer queued notes"
        try db.removePendingWrite(seq: #require(rewritten.seq))
        try db.requeue(PendingWrite(entity: .project, entityId: project.id, op: .patch,
            body: JSONSerialization.data(withJSONObject: current), createdAt: Fixtures.t0))
        let before = try #require(try db.pendingWrites().first { $0.entity == .project })
        try db.resolveDroppedWrite(deletion, serverCopy: .live(category))
        let after = try #require(try db.pendingWrites().first { $0.entity == .project })
        #expect(after.op == .patch && after.seq == before.seq)
        #expect(try fields(after)["categoryId"] as? String == category.id)
        #expect(try withoutCategory(after) == withoutCategory(before))
        #expect(try db.project(id: project.id)?.categoryId == category.id)
    }

    @Test(arguments: [false, true])
    func laterDeliberateFilingIncludingAwayThenBackIsNotRolledBack(_ backToUnfiled: Bool) throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let task = Fixtures.task(id: "moved", categoryId: category.id)
        let untouched = Fixtures.task(id: "untouched", categoryId: category.id)
        let project = project("moved-project")
        let untouchedProject = self.project("untouched-project")
        try db.apply(SyncResponse(cursor: "c", categories: [category, Fixtures.category(id: "other")],
            tasks: [task, untouched], projects: [project, untouchedProject]))
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first)
        var changedTask = try #require(try db.task(id: task.id))
        changedTask.categoryId = "other"
        changedTask.notes = "Keep my task notes"
        try db.saveTask(changedTask)
        var changedProject = try #require(try db.project(id: project.id))
        changedProject.categoryId = "other"
        changedProject.notes = "Keep my project notes"
        try db.saveProject(changedProject)
        if backToUnfiled {
            changedTask.categoryId = TaskCategory.inboxId
            try db.saveTask(changedTask)
            changedProject.categoryId = nil
            try db.saveProject(changedProject)
        }
        let beforeTask = try #require(try db.pendingWrites().first { $0.entity == .task })
        let beforeProject = try #require(try db.pendingWrites().first { $0.entity == .project })
        let reopened = try AppDatabase(writer: db.writer)
        try reopened.resolveDroppedWrite(deletion, serverCopy: .live(category))
        #expect(try reopened.task(id: task.id)?.categoryId == changedTask.categoryId)
        #expect(try reopened.project(id: project.id)?.categoryId == changedProject.categoryId)
        #expect(try reopened.task(id: task.id)?.notes == changedTask.notes)
        #expect(try reopened.project(id: project.id)?.notes == changedProject.notes)
        #expect(try reopened.pendingWrites().first { $0.entity == .task }?.body == beforeTask.body)
        #expect(try reopened.pendingWrites().first { $0.entity == .project }?.body == beforeProject.body)
        #expect(try reopened.task(id: untouched.id)?.categoryId == category.id)
        #expect(try reopened.project(id: untouchedProject.id)?.categoryId == category.id)
    }

    @Test func acceptedCategoryDeletionCannotRestoreOldReferencesOnLaterCategoryRecreation() throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let task = Fixtures.task(id: "task", categoryId: category.id)
        let project = project()
        try db.apply(SyncResponse(cursor: "c", categories: [category], tasks: [task], projects: [project]))
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first)
        try db.completePendingWrite(deletion, record: nil as TaskCategory?, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
        let reopened = try AppDatabase(writer: db.writer)
        try reopened.apply(SyncResponse(cursor: "new-category", categories: [category]))
        #expect(try reopened.task(id: task.id)?.categoryId == TaskCategory.inboxId)
        #expect(try reopened.project(id: project.id)?.categoryId == nil)
        #expect(try reopened.pendingWrites().isEmpty)
    }

    @Test func discardedDeleteCanRecoverOnTheNextPullWhenItsReconciliationFailed() async throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let task = Fixtures.task(id: "task", categoryId: category.id)
        let project = project()
        try db.apply(SyncResponse(cursor: "old-cursor", categories: [category], tasks: [task], projects: [project]))
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first)
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let failedClient = SyncClient(database: db, config: config, transport: FakeTransport([.failure(NetworkDown())]))
        await #expect(throws: SyncError.self) { try await failedClient.discard(deletion) }
        let reopened = try AppDatabase(writer: db.writer)
        #expect(try reopened.cursor() == nil)
        let transport = FakeTransport([try .ok(SyncResponse(cursor: "recovered", categories: [category]))])
        let client = SyncClient(database: reopened, config: config, transport: transport)
        try await client.pull()
        #expect(transport.requests.first?.query["since"] == nil)
        #expect(try reopened.task(id: task.id)?.categoryId == category.id)
        #expect(try reopened.project(id: project.id)?.categoryId == category.id)
        #expect(try reopened.pendingWrites().isEmpty)
    }

    @Test(arguments: [false, true])
    func serverConfirmedDeletionKeepsReassignmentAndForgetsRollback(_ missing: Bool) async throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let task = Fixtures.task(id: "task", categoryId: category.id)
        let project = project()
        try db.apply(SyncResponse(cursor: "c", categories: [category], tasks: [task], projects: [project]))
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first)
        try db.removePendingWrite(seq: #require(deletion.seq))
        try db.apply(SyncResponse(cursor: "older-response", tasks: [task], projects: [project]))
        var tombstone = category
        tombstone.deletedAt = Fixtures.t0
        let transport = FakeTransport([missing ? .error(404, "category not found") : try .ok(tombstone)])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        try await client.discard(deletion)
        #expect(try db.task(id: task.id)?.categoryId == TaskCategory.inboxId)
        #expect(try db.project(id: project.id)?.categoryId == nil)
        try db.apply(SyncResponse(cursor: "recreated-category", categories: [category]))
        #expect(try db.task(id: task.id)?.categoryId == TaskCategory.inboxId)
        #expect(try db.project(id: project.id)?.categoryId == nil)
        #expect(try db.pendingWrites().isEmpty)
    }
}
