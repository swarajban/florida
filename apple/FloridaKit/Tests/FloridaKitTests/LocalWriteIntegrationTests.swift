import Foundation
import Testing
@testable import FloridaKit

@Suite struct LocalWriteIntegrationTests {
    @Test func originalAwareFilingAndMutationSnapshotsSurviveCategoryRollback() throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let task = Fixtures.task(id: "task", categoryId: category.id)
        let project = Project(id: "project", name: "Project", categoryId: category.id,
            createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        try db.apply(SyncResponse(cursor: "c", categories: [category, Fixtures.category(id: "other")],
            tasks: [task], projects: [project]))
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first)
        let taskOriginal = try #require(try db.task(id: task.id))
        let projectOriginal = try #require(try db.project(id: project.id))
        var taskDraft = taskOriginal
        taskDraft.categoryId = "other"
        taskDraft.notes = "Keep task notes"
        let moved = try db.saveTask(taskDraft, original: taskOriginal)
        #expect(moved.before?.categoryId == TaskCategory.inboxId)
        #expect(moved.after.categoryId == "other")
        var projectDraft = projectOriginal
        projectDraft.categoryId = "other"
        projectDraft.notes = "Keep project notes"
        try db.saveProject(projectDraft, original: projectOriginal)
        taskDraft = moved.after
        taskDraft.categoryId = TaskCategory.inboxId
        let unfiled = try db.saveTask(taskDraft, original: moved.after)
        let movedProject = try #require(try db.project(id: project.id))
        projectDraft = movedProject
        projectDraft.categoryId = nil
        try db.saveProject(projectDraft, original: movedProject)
        try db.resolveDroppedWrite(deletion, serverCopy: .live(category))
        #expect(unfiled.before?.categoryId == "other")
        #expect(unfiled.after.categoryId == TaskCategory.inboxId)
        #expect(try db.task(id: task.id)?.categoryId == TaskCategory.inboxId)
        #expect(try db.project(id: project.id)?.categoryId == nil)
        #expect(try db.task(id: task.id)?.notes == "Keep task notes")
        #expect(try db.project(id: project.id)?.notes == "Keep project notes")
        #expect(try db.pendingWrites().count == 2)
    }
}
