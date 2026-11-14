import FloridaKit
import Foundation
import Testing

@Suite struct TaskUndoTests {
    private let now = Date(timeIntervalSince1970: 1_794_614_400)

    private func task() -> TaskItem {
        TaskItem(
            id: "undo-task", categoryId: "home", title: "Keep this task", durationMinutes: 30,
            createdAt: now, updatedAt: now,
            source: TaskSource(url: "https://example.com/original", title: "Original source", kind: .web))
    }

    private func changed(_ before: TaskItem, decision: String) -> TaskItem {
        var after = before
        switch decision {
        case "due":
            after.dueAt = now.addingTimeInterval(86_400)
            after.deadlineType = .soft
        case "start":
            after.startAt = now.addingTimeInterval(86_400)
        case "pin":
            after.pinnedStart = now.addingTimeInterval(3_600)
        default:
            after.someday = true
        }
        return after
    }

    private func applyUndo(_ undo: TaskUndo, in database: AppDatabase) throws {
        if let current = try database.task(id: undo.taskId) {
            guard undo.stillApplies(to: current) else { return }
            try database.saveTask(undo.reverted(current), now: now.addingTimeInterval(600))
        } else if var restored = undo.deleted {
            restored.deletedAt = nil
            try database.saveTask(restored, now: now.addingTimeInterval(600))
        }
    }

    @Test(arguments: ["due", "start", "pin", "someday"])
    func dateUndoAfterRemoteCompletionWritesNothing(decision: String) throws {
        let database = try AppDatabase.inMemory()
        let before = task()
        let after = changed(before, decision: decision)
        let undo = try #require(TaskUndo(from: before, to: after))
        try database.apply(SyncResponse(cursor: "action-synced", tasks: [after]))
        var completed = after
        completed.completedAt = now.addingTimeInterval(60)
        completed.completedMinutes = completed.durationMinutes
        completed.updatedAt = now.addingTimeInterval(60)
        try database.apply(SyncResponse(cursor: "remote-completion", tasks: [completed]))
        #expect(!undo.stillApplies(to: completed))
        try applyUndo(undo, in: database)
        #expect(try database.pendingWrites().isEmpty)
        #expect(try database.task(id: before.id) == completed)
    }

    @Test(arguments: ["due", "start", "pin", "someday"])
    func dateUndoAfterRetainedRemoteTombstoneWritesNothing(decision: String) throws {
        let database = try AppDatabase.inMemory()
        let before = task()
        let after = changed(before, decision: decision)
        let undo = try #require(TaskUndo(from: before, to: after))
        try database.apply(SyncResponse(cursor: "action-synced", tasks: [after]))
        let deletedAt = now.addingTimeInterval(60)
        try database.writer.write {
            try $0.execute(sql: "UPDATE task SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                           arguments: [deletedAt, deletedAt, before.id])
        }
        let tombstone = try #require(try database.task(id: before.id))
        #expect(tombstone.deletedAt != nil)
        #expect(!undo.stillApplies(to: tombstone))
        try applyUndo(undo, in: database)
        #expect(try database.pendingWrites().isEmpty)
        #expect(try database.task(id: before.id) == tombstone)
    }

    @Test func dateUndoAfterPulledTombstoneDoesNotRestoreMissingRow() throws {
        let database = try AppDatabase.inMemory()
        let before = task()
        let after = changed(before, decision: "someday")
        let undo = try #require(TaskUndo(from: before, to: after))
        try database.apply(SyncResponse(cursor: "action-synced", tasks: [after]))
        var tombstone = after
        tombstone.deletedAt = now.addingTimeInterval(60)
        try database.apply(SyncResponse(cursor: "remote-delete", tasks: [tombstone]))
        #expect(try database.task(id: before.id) == nil)
        try applyUndo(undo, in: database)
        #expect(try database.pendingWrites().isEmpty)
        #expect(try database.task(id: before.id) == nil)
    }

    @Test func completionUndoStillReopensTask() throws {
        let database = try AppDatabase.inMemory()
        let before = task()
        var after = before
        after.completedAt = now.addingTimeInterval(60)
        after.completedMinutes = after.durationMinutes
        let undo = try #require(TaskUndo(from: before, to: after))
        #expect(undo.stillApplies(to: after))
        #expect(undo.reverted(after) == before)
        var echo = after
        echo.completedAt = after.completedAt?.addingTimeInterval(0.5)
        #expect(undo.stillApplies(to: echo))
        #expect(undo.reverted(echo) == before)
        try database.apply(SyncResponse(cursor: "completion-synced", tasks: [echo]))
        try applyUndo(undo, in: database)
        let reopened = try #require(try database.task(id: before.id))
        #expect(reopened.isOpen && reopened.completedMinutes == before.completedMinutes)
        #expect(reopened.source == before.source)
        #expect(try database.pendingWrites().first?.op == .patch)
    }

    @Test func deleteUndoAcceptsChangedServerTombstoneTimestamp() throws {
        let database = try AppDatabase.inMemory()
        let before = task()
        var after = before
        after.deletedAt = now.addingTimeInterval(60)
        let undo = try #require(TaskUndo(from: before, to: after))
        #expect(undo.deleted == before)
        var echo = after
        echo.deletedAt = now.addingTimeInterval(120)
        #expect(undo.stillApplies(to: echo))
        #expect(undo.reverted(echo) == before)
        try database.apply(SyncResponse(cursor: "before-delete", tasks: [before]))
        try database.writer.write {
            try $0.execute(sql: "UPDATE task SET deletedAt = ? WHERE id = ?",
                           arguments: [echo.deletedAt, before.id])
        }
        try applyUndo(undo, in: database)
        let restored = try #require(try database.task(id: before.id))
        #expect(restored.isOpen && restored.source == before.source)
        #expect(try database.pendingWrites().first?.op == .put)
    }

    @Test func deleteUndoStillRestoresMissingRowAfterPulledTombstone() throws {
        let database = try AppDatabase.inMemory()
        let before = task()
        var after = before
        after.deletedAt = now.addingTimeInterval(60)
        let undo = try #require(TaskUndo(from: before, to: after))
        try database.apply(SyncResponse(cursor: "before-delete", tasks: [before]))
        try database.apply(SyncResponse(cursor: "delete-synced", tasks: [after]))
        #expect(try database.task(id: before.id) == nil)
        try applyUndo(undo, in: database)
        let restored = try #require(try database.task(id: before.id))
        #expect(restored.isOpen && restored.source == before.source)
        #expect(try database.pendingWrites().first?.op == .put)
    }

    @Test func deleteUndoRejectsCompletionAfterDelete() throws {
        let before = task()
        var after = before
        after.deletedAt = now.addingTimeInterval(60)
        let undo = try #require(TaskUndo(from: before, to: after))
        after.completedAt = now.addingTimeInterval(120)
        #expect(!undo.stillApplies(to: after))
    }

    @Test func dateUndoPreservesSourceAndUnrelatedEdits() throws {
        let database = try AppDatabase.inMemory()
        let before = task()
        let after = changed(before, decision: "due")
        let undo = try #require(TaskUndo(from: before, to: after))
        var current = after
        current.title = "Remote title"
        current.notes = "Remote notes"
        current.source = TaskSource(url: "https://example.com/latest", title: "Latest source", kind: .web)
        try database.apply(SyncResponse(cursor: "remote-edit", tasks: [current]))
        #expect(undo.stillApplies(to: current))
        try applyUndo(undo, in: database)
        let reverted = try #require(try database.task(id: before.id))
        #expect(reverted.title == current.title)
        #expect(reverted.notes == current.notes)
        #expect(reverted.source == current.source)
        #expect(reverted.dueAt == before.dueAt && reverted.deadlineType == before.deadlineType)
        let write = try #require(try database.pendingWrites().first)
        #expect(write.op == .patch)
        let body = try #require(write.body)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields["source"] == nil && fields["title"] == nil && fields["notes"] == nil)
    }

    @Test func unchangedActionHasNoUndo() {
        #expect(TaskUndo(from: task(), to: task()) == nil)
    }
}
