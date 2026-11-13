import Foundation
import Testing
@testable import FloridaKit

private enum RemoteFilingPath: CaseIterable, Sendable {
    case pull, accepted, reconciled
}

private enum RemoteFiling: CaseIterable, Sendable {
    case unfiled, other, work

    var taskCategory: String { self == .unfiled ? TaskCategory.inboxId : self == .other ? "other" : "work" }
    var projectCategory: String? { self == .unfiled ? nil : self == .other ? "other" : "work" }
}

private enum ProtectedFiling: CaseIterable, Sendable {
    case titleOnly, other, awayThenUnfiled
}

@Suite struct CategoryRemoteFilingTests {
    private func seed() throws -> (AppDatabase, TaskItem, Project, TaskCategory) {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let task = Fixtures.task(id: "task", categoryId: category.id)
        let project = Project(id: "project", name: "Project", categoryId: category.id, createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        try db.apply(SyncResponse(cursor: "c", categories: [category, Fixtures.category(id: "other")], tasks: [task], projects: [project]))
        return (db, task, project, category)
    }

    @Test(arguments: RemoteFilingPath.allCases, RemoteFiling.allCases)
    private func appliedRemoteFilingSurvivesCategoryRollback(_ path: RemoteFilingPath, _ filing: RemoteFiling) throws {
        try verifyApplied(path, filing: filing, laterText: false)
    }

    @Test(arguments: RemoteFilingPath.allCases, RemoteFiling.allCases)
    private func appliedRemoteFilingSurvivesLaterUnrelatedText(_ path: RemoteFilingPath, _ filing: RemoteFiling) throws {
        try verifyApplied(path, filing: filing, laterText: true)
    }

    private func verifyApplied(_ path: RemoteFilingPath, filing: RemoteFiling, laterText: Bool) throws {
        let (db, originalTask, originalProject, category) = try seed()
        var remoteTask = originalTask
        var remoteProject = originalProject
        if path != .pull {
            remoteTask.title = "In-flight task title"
            remoteProject.name = "In-flight project name"
            try db.saveTask(remoteTask)
            try db.saveProject(remoteProject)
        }
        let inFlight = try db.pendingWrites()
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first { $0.entity == .category })
        remoteTask.categoryId = filing.taskCategory
        remoteProject.categoryId = filing.projectCategory
        remoteTask.notes = "Remote task notes"
        remoteProject.notes = "Remote project notes"
        if path == .pull {
            try db.apply(SyncResponse(cursor: "remote", tasks: [remoteTask], projects: [remoteProject]))
        } else {
            let taskWrite = try #require(inFlight.first { $0.entity == .task })
            let projectWrite = try #require(inFlight.first { $0.entity == .project })
            if path == .accepted {
                try db.completePendingWrite(taskWrite, record: remoteTask, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
                try db.completePendingWrite(projectWrite, record: remoteProject, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
            } else {
                try db.resolveDroppedWrite(taskWrite, serverCopy: .live(remoteTask))
                try db.resolveDroppedWrite(projectWrite, serverCopy: .live(remoteProject))
            }
        }
        if laterText {
            var task = try #require(try db.task(id: remoteTask.id))
            var project = try #require(try db.project(id: remoteProject.id))
            task.title = "Later task title"
            task.notes = "Later task notes"
            project.name = "Later project name"
            project.notes = "Later project notes"
            try db.saveTask(task)
            try db.saveProject(project)
        }
        let taskBeforeRollback = try #require(try db.task(id: remoteTask.id))
        let projectBeforeRollback = try #require(try db.project(id: remoteProject.id))
        let reopened = try AppDatabase(writer: db.writer)
        if laterText { try reopened.removePendingWrite(seq: #require(deletion.seq)) }
        try reopened.resolveDroppedWrite(deletion, serverCopy: .live(category))
        #expect(try reopened.task(id: remoteTask.id)?.categoryId == filing.taskCategory)
        #expect(try reopened.project(id: remoteProject.id)?.categoryId == filing.projectCategory)
        #expect(try reopened.task(id: remoteTask.id)?.title == taskBeforeRollback.title)
        #expect(try reopened.task(id: remoteTask.id)?.notes == taskBeforeRollback.notes)
        #expect(try reopened.project(id: remoteProject.id)?.name == projectBeforeRollback.name)
        #expect(try reopened.project(id: remoteProject.id)?.notes == projectBeforeRollback.notes)
        if laterText {
            let taskWrite = try #require(try reopened.pendingWrites().first { $0.entity == .task })
            let projectWrite = try #require(try reopened.pendingWrites().first { $0.entity == .project })
            let taskBody = try #require(taskWrite.body)
            let projectBody = try #require(projectWrite.body)
            let taskFields = try #require(JSONSerialization.jsonObject(with: taskBody) as? [String: Any])
            let projectFields = try #require(JSONSerialization.jsonObject(with: projectBody) as? [String: Any])
            #expect(taskFields["categoryId"] == nil)
            #expect(projectFields["categoryId"] as? String == filing.projectCategory)
            #expect(taskFields["notes"] as? String == "Later task notes")
            #expect(projectFields["notes"] as? String == "Later project notes")
        }
    }

    @Test(arguments: RemoteFilingPath.allCases, ProtectedFiling.allCases)
    private func protectedRemoteRowsDoNotInvalidatePendingLocalIntent(_ path: RemoteFilingPath, _ filing: ProtectedFiling) throws {
        let (db, originalTask, originalProject, category) = try seed()
        var task = originalTask
        var project = originalProject
        task.title = "First local task title"
        project.name = "First local project name"
        try db.saveTask(task)
        try db.saveProject(project)
        let firstWrites = try db.pendingWrites()
        try db.deleteCategory(id: category.id)
        let deletion = try #require(try db.pendingWrites().first { $0.entity == .category })
        task = try #require(try db.task(id: task.id))
        project = try #require(try db.project(id: project.id))
        if filing != .titleOnly {
            task.categoryId = "other"
            project.categoryId = "other"
        }
        task.title = "Protected task title"
        task.notes = "Protected task notes"
        project.name = "Protected project name"
        project.notes = "Protected project notes"
        try db.saveTask(task)
        try db.saveProject(project)
        if filing == .awayThenUnfiled {
            task.categoryId = TaskCategory.inboxId
            project.categoryId = nil
            try db.saveTask(task)
            try db.saveProject(project)
        }
        let before = try db.pendingWrites()
        var remoteTask = originalTask
        var remoteProject = originalProject
        if filing != .awayThenUnfiled {
            remoteTask.categoryId = TaskCategory.inboxId
            remoteProject.categoryId = nil
        }
        remoteTask.notes = "Skipped remote task notes"
        remoteProject.notes = "Skipped remote project notes"
        if path == .pull {
            try db.apply(SyncResponse(cursor: "protected", tasks: [remoteTask], projects: [remoteProject]))
        } else {
            let firstTask = try #require(firstWrites.first { $0.entity == .task })
            let firstProject = try #require(firstWrites.first { $0.entity == .project })
            if path == .accepted {
                try db.completePendingWrite(firstTask, record: remoteTask, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
                try db.completePendingWrite(firstProject, record: remoteProject, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
            } else {
                try db.resolveDroppedWrite(firstTask, serverCopy: .live(remoteTask))
                try db.resolveDroppedWrite(firstProject, serverCopy: .live(remoteProject))
            }
        }
        #expect(try db.pendingWrites() == before)
        #expect(try db.task(id: task.id)?.categoryId == task.categoryId)
        #expect(try db.project(id: project.id)?.categoryId == project.categoryId)
        #expect(try db.task(id: task.id)?.notes == task.notes)
        #expect(try db.project(id: project.id)?.notes == project.notes)
        try db.resolveDroppedWrite(deletion, serverCopy: .live(category))
        let expectedTask = filing == .titleOnly ? "work" : task.categoryId
        let expectedProject = filing == .titleOnly ? "work" : project.categoryId
        #expect(try db.task(id: task.id)?.categoryId == expectedTask)
        #expect(try db.project(id: project.id)?.categoryId == expectedProject)
        #expect(try db.task(id: task.id)?.notes == task.notes)
        #expect(try db.project(id: project.id)?.notes == project.notes)
    }
}
