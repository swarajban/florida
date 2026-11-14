import Foundation
import Testing
@testable import FloridaCore

@Suite struct TaskUndoTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    private func task() -> TaskItem {
        TaskItem(id: "task", categoryId: "inbox", title: "Original", durationMinutes: 60,
                 priority: .medium, deadlineType: .none, createdAt: now, updatedAt: now)
    }

    @Test func everyEditorFieldIsRevertedTogether() throws {
        let before = task()
        var after = before
        after.categoryId = "work"
        after.title = "Edited"
        after.notes = "Notes"
        after.source = TaskSource.from(url: "https://example.com/task")
        after.durationMinutes = 90
        after.minChunkMinutes = 15
        after.priority = .high
        after.deadlineType = .hard
        after.dueAt = now.addingTimeInterval(3_600)
        after.startAt = now
        after.scheduleId = "schedule"
        after.context = .errand
        after.projectId = "project"
        after.attention = .shared
        after.pinnedStart = now
        after.completedMinutes = 90
        after.completedAt = now
        after.recurrence = TaskRecurrence(frequency: .week, timeZone: "UTC", startDate: "2026-11-09")
        let undo = try #require(TaskUndo(from: before, to: after))
        #expect(undo.stillApplies(to: after))
        #expect(undo.reverted(after) == before)
    }

    @Test func untouchedFieldsAndServerMetadataSurviveUndo() throws {
        let before = task()
        var after = before
        after.title = "Edited"
        let undo = try #require(TaskUndo(from: before, to: after))
        var live = after
        live.notes = "Remote notes"
        live.recurrenceSeriesId = "server-series"
        live.recurrenceDate = "2026-11-16"
        live.recurrenceRevision = "server-revision"
        live.updatedAt = now.addingTimeInterval(10)
        #expect(undo.stillApplies(to: live))
        let restored = undo.reverted(live)
        #expect(restored.title == before.title && restored.notes == "Remote notes")
        #expect(restored.recurrenceSeriesId == live.recurrenceSeriesId)
        #expect(restored.recurrenceDate == live.recurrenceDate)
        #expect(restored.recurrenceRevision == live.recurrenceRevision && restored.updatedAt == live.updatedAt)
    }

    @Test func changedFieldsAndLaterCompletionRefuseUndo() throws {
        let before = task()
        var after = before
        after.title = "Edited"
        let undo = try #require(TaskUndo(from: before, to: after))
        var live = after
        live.title = "Changed again"
        #expect(!undo.stillApplies(to: live))
        live = after
        live.completedAt = now
        #expect(!undo.stillApplies(to: live))
        live = after
        live.deletedAt = now
        #expect(!undo.stillApplies(to: live))
    }

    @Test func deleteKeepsFullSnapshotAndIgnoresServerTombstoneTime() throws {
        let before = task()
        var after = before
        after.deletedAt = now
        let undo = try #require(TaskUndo(from: before, to: after))
        #expect(undo.deleted == before)
        var echo = after
        echo.deletedAt = now.addingTimeInterval(10)
        #expect(undo.stillApplies(to: echo))
        #expect(undo.reverted(echo).deletedAt == nil)
    }

    @Test func metadataOnlyChangesDoNotCreateUndo() {
        let before = task()
        var after = before
        after.updatedAt = now.addingTimeInterval(10)
        after.recurrenceSeriesId = "series"
        after.recurrenceDate = "2026-11-09"
        after.recurrenceRevision = "revision"
        #expect(TaskUndo(from: before, to: after) == nil)
    }

    @Test(arguments: [false, true])
    func somedayOnlyChangeIsTrackedAndRevertedExactly(_ someday: Bool) throws {
        var before = task()
        before.someday = !someday
        var after = before
        after.someday = someday
        let undo = try #require(TaskUndo(from: before, to: after))
        #expect(undo.stillApplies(to: after))
        #expect(undo.reverted(after) == before)
        #expect(!undo.stillApplies(to: before))
        var closed = after
        closed.completedAt = now
        #expect(!undo.stillApplies(to: closed))
        closed = after
        closed.deletedAt = now
        #expect(!undo.stillApplies(to: closed))
    }

    @Test func normalizedSomedayUndoRestoresDatesAndPreservesUnrelatedChanges() throws {
        var before = task()
        before.dueAt = now
        before.pinnedStart = now.addingTimeInterval(3600)
        before.startAt = now.addingTimeInterval(7200)
        before.deadlineType = .hard
        var after = before
        after.someday = true
        after.dueAt = nil
        after.pinnedStart = nil
        after.deadlineType = .none
        let undo = try #require(TaskUndo(from: before, to: after))
        #expect(undo.reverted(after) == before)
        var live = after
        live.title = "Latest title"
        live.notes = "Latest notes"
        live.recurrenceRevision = "latest-revision"
        #expect(undo.stillApplies(to: live))
        let restored = undo.reverted(live)
        #expect(!restored.someday && restored.dueAt == before.dueAt && restored.pinnedStart == before.pinnedStart)
        #expect(restored.deadlineType == before.deadlineType && restored.startAt == before.startAt)
        #expect(restored.title == live.title && restored.notes == live.notes)
        #expect(restored.recurrenceRevision == live.recurrenceRevision)
    }

    @Test func unrelatedUndoPreservesLatestSomeday() throws {
        let before = task()
        var after = before
        after.title = "Edited"
        let undo = try #require(TaskUndo(from: before, to: after))
        var live = after
        live.someday = true
        #expect(undo.stillApplies(to: live))
        #expect(undo.reverted(live).someday)
    }
}
