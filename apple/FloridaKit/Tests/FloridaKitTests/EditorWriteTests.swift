import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct EditorWriteTests {
    private func store() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "initial", categories: [Fixtures.category()]))
        return db
    }

    private func project() -> Project {
        Project(id: "project", name: "Original", createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
    }

    private func event() -> CalendarEvent {
        Fixtures.event(id: "event", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z")
    }

    @Test func rsvpUpdatesLiveSelfAttendeeWithoutRevertingOtherGuests() throws {
        let db = try store()
        var original = event()
        original.responseStatus = "needsAction"
        original.attendees = [
            EventAttendee(email: "me@example.com", responseStatus: "needsAction", isSelf: true),
            EventAttendee(email: "guest@example.com", responseStatus: "accepted"),
        ]
        var live = original
        live.attendees = [
            EventAttendee(email: "me@example.com", responseStatus: "needsAction", isSelf: true),
            EventAttendee(email: "guest@example.com", responseStatus: "declined"),
            EventAttendee(email: "new@example.com", responseStatus: "tentative"),
        ]
        try db.apply(SyncResponse(cursor: "changed-guests", events: [live]))
        var draft = original
        draft.responseStatus = "accepted"
        draft.attendees?[0].responseStatus = "accepted"
        try db.saveEvent(draft, original: original)
        let saved = try #require(try db.event(id: original.id))
        #expect(saved.responseStatus == "accepted")
        #expect(saved.attendees?.first(where: \.isSelf)?.responseStatus == "accepted")
        #expect(saved.attendees?.filter { !$0.isSelf } == live.attendees?.filter { !$0.isSelf })
        let pending = try #require(try db.pendingWrites().first { $0.entity == .event })
        let data = try #require(pending.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["responseStatus"] as? String == "accepted")
        #expect(body["attendees"] == nil)
    }

    @Test func taskEditorPreservesUntouchedLiveFieldsAndExplicitClears() throws {
        let db = try store()
        var original = Fixtures.task(id: "task")
        original.notes = "Clear me"
        try db.apply(SyncResponse(cursor: "opened", tasks: [original]))
        var live = original
        live.priority = .high
        live.completedMinutes = 20
        live.recurrenceRevision = "new-revision"
        try db.apply(SyncResponse(cursor: "changed", tasks: [live]))
        var draft = original
        draft.title = "My title"
        draft.notes = nil
        let mutation = try db.saveTask(draft, original: original, now: Fixtures.t0)
        let saved = try #require(try db.task(id: original.id))
        #expect(mutation.before == live && mutation.after == saved)
        #expect(saved.title == "My title" && saved.notes == nil)
        #expect(saved.priority == .high && saved.completedMinutes == 20)
        #expect(saved.recurrenceRevision == "new-revision")
        let body = try body(db)
        #expect(Set(body.keys) == ["title", "notes", "expectedRecurrenceRevision"])
        #expect(body["notes"] is NSNull)
        #expect(body["expectedRecurrenceRevision"] as? String == "new-revision")
    }

    @Test(arguments: [false, true])
    func taskEditorRefusesDeletedOrCompletedLiveRows(_ completed: Bool) throws {
        let db = try store()
        let original = Fixtures.task(id: "task")
        try db.apply(SyncResponse(cursor: "opened", tasks: [original]))
        var live = original
        if completed { live.completedAt = Fixtures.t0 } else { live.deletedAt = Fixtures.t0 }
        try db.apply(SyncResponse(cursor: "changed", tasks: [live]))
        var draft = original
        draft.title = "Do not resurrect"
        #expect(throws: (any Error).self) { try db.saveTask(draft, original: original) }
        #expect(try db.task(id: original.id) == (completed ? live : nil))
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func taskEditorCoercesDeletedDestinationsWithoutLosingTitle() throws {
        let db = try store()
        var original = Fixtures.task(id: "task", categoryId: "removed")
        original.projectId = "removed"
        try db.apply(SyncResponse(cursor: "opened", tasks: [original]))
        var draft = original
        draft.title = "Keep my edit"
        try db.saveTask(draft, original: original)
        let saved = try #require(try db.task(id: original.id))
        #expect(saved.categoryId == "inbox" && saved.projectId == nil)
        #expect(saved.title == "Keep my edit")
        let body = try body(db)
        #expect(body["categoryId"] as? String == "inbox")
        #expect(body["projectId"] is NSNull)
    }

    @Test func newEditorCoercesDeletedTaskAndProjectDestinations() throws {
        let db = try store()
        var task = Fixtures.task(id: "new", categoryId: "removed")
        task.projectId = "removed"
        try db.saveTask(task, original: nil)
        #expect(try db.task(id: task.id)?.categoryId == "inbox")
        #expect(try db.task(id: task.id)?.projectId == nil)
        var project = project()
        project.categoryId = "removed"
        try db.saveProject(project, original: nil)
        #expect(try db.project(id: project.id)?.categoryId == nil)
    }

    @Test func noOpEditorDoesNotQueueOrRestoreStaleData() throws {
        let db = try store()
        let original = Fixtures.task(id: "task")
        var live = original
        live.title = "New remote title"
        try db.apply(SyncResponse(cursor: "changed", tasks: [live]))
        try db.saveTask(original, original: original)
        #expect(try db.task(id: live.id) == live)
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func reducingDurationToLoggedProgressCompletesTask() throws {
        let db = try store()
        var original = Fixtures.task(id: "task")
        original.completedMinutes = 30
        try db.apply(SyncResponse(cursor: "opened", tasks: [original]))
        var draft = original
        draft.durationMinutes = 30
        try db.saveTask(draft, original: original, now: Fixtures.t0)
        let saved = try #require(try db.task(id: original.id))
        #expect(saved.completedAt == Fixtures.t0)
        #expect(saved.remainingMinutes == 0 && !saved.isOpen)
    }

    @Test func deliberateReopenPreservesUneditedLiveFields() throws {
        let db = try store()
        var original = Fixtures.task(id: "task", completedAt: Fixtures.t0)
        original.completedMinutes = original.durationMinutes
        var live = original
        live.notes = "Updated after completion"
        try db.apply(SyncResponse(cursor: "changed", tasks: [live]))
        var draft = original
        draft.completedAt = nil
        draft.completedMinutes = 0
        try db.saveTask(draft, original: original)
        let saved = try #require(try db.task(id: original.id))
        #expect(saved.isOpen && saved.completedMinutes == 0)
        #expect(saved.notes == live.notes)
    }

    @Test func rejectedUndoPredicateDoesNotWriteOrQueue() throws {
        let db = try store()
        let task = Fixtures.task(id: "task")
        try db.apply(SyncResponse(cursor: "opened", tasks: [task]))
        let applied = try db.updateTask(id: task.id) { live in
            live.title = "Never persisted"
            return false
        }
        #expect(!applied)
        #expect(try db.task(id: task.id) == task)
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func undoReadsAndPreservesLiveUnchangedFields() throws {
        let db = try store()
        var task = Fixtures.task(id: "task", priority: .high, completedAt: Fixtures.t0)
        task.notes = "Changed on another device"
        try db.apply(SyncResponse(cursor: "changed", tasks: [task]))
        let applied = try db.updateTask(id: task.id, now: Fixtures.t0) { live in
            guard live.completedAt == Fixtures.t0 else { return false }
            live.completedAt = nil
            return true
        }
        #expect(applied)
        let saved = try #require(try db.task(id: task.id))
        #expect(saved.completedAt == nil && saved.priority == .high)
        #expect(saved.notes == "Changed on another device")
        #expect(Set(try body(db).keys) == ["completedAt"])
    }

    @Test func eventEditorPreservesUntouchedLiveFieldsAndMetadata() throws {
        let db = try store()
        let original = event()
        var live = original
        live.location = "New room"
        live.responseStatus = "tentative"
        live.googleId = "latest-google-id"
        try db.apply(SyncResponse(cursor: "changed", events: [live]))
        var draft = original
        draft.summary = "My title"
        try db.saveEvent(draft, original: original)
        let saved = try #require(try db.event(id: original.id))
        #expect(saved.summary == "My title")
        #expect(saved.location == "New room" && saved.responseStatus == "tentative")
        #expect(saved.googleId == "latest-google-id")
    }

    @Test func eventEditorRefusesDeletedRows() throws {
        let db = try store()
        let original = event()
        try db.apply(SyncResponse(cursor: "initial", events: [original]))
        var removed = original
        removed.deletedAt = Fixtures.t0
        try db.apply(SyncResponse(cursor: "deleted", events: [removed]))
        var draft = original
        draft.summary = "Do not recreate on Google"
        #expect(throws: (any Error).self) { try db.saveEvent(draft, original: original) }
        #expect(try db.event(id: original.id) == nil)
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func projectEditorPreservesUntouchedFieldsAndClearsMissingCategory() throws {
        let db = try store()
        var original = project()
        original.categoryId = "removed"
        var live = original
        live.notes = "Remote notes"
        live.weeklyMinutes = 120
        try db.apply(SyncResponse(cursor: "changed", projects: [live]))
        var draft = original
        draft.name = "My name"
        try db.saveProject(draft, original: original)
        let saved = try #require(try db.project(id: original.id))
        #expect(saved.name == "My name" && saved.categoryId == nil)
        #expect(saved.notes == "Remote notes" && saved.weeklyMinutes == 120)
    }

    @Test func projectEditorRefusesDeletedRows() throws {
        let db = try store()
        let original = project()
        var draft = original
        draft.name = "Do not resurrect"
        #expect(throws: (any Error).self) { try db.saveProject(draft, original: original) }
        #expect(try db.project(id: original.id) == nil)
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func deleteUndoAfterAcknowledgementRestoresFullSnapshotAndExplainsSeriesLoss() throws {
        let db = try store()
        var snapshot = Fixtures.task(id: "task", categoryId: "removed", dueAt: Fixtures.t0)
        snapshot.projectId = "removed"
        snapshot.notes = "All of my notes"
        snapshot.priority = .high
        snapshot.recurrence = TaskRecurrence(frequency: .week, timeZone: "UTC", startDate: "2026-11-09")
        snapshot.recurrenceSeriesId = "series"
        snapshot.recurrenceDate = "2026-11-09"
        snapshot.recurrenceRevision = "revision"
        try db.apply(SyncResponse(cursor: "opened", tasks: [snapshot]))
        try db.deleteTask(id: snapshot.id, now: Fixtures.t0)
        let deletion = try #require(try db.pendingWrites().first)
        try db.completePendingWrite(deletion, record: nil as TaskItem?, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
        #expect(try db.task(id: snapshot.id) == nil)
        #expect(try db.restoreTask(snapshot, now: Fixtures.t0))
        let restored = try #require(try db.task(id: snapshot.id))
        #expect(restored.title == snapshot.title && restored.notes == snapshot.notes)
        #expect(restored.priority == snapshot.priority && restored.dueAt == snapshot.dueAt)
        #expect(restored.categoryId == "inbox" && restored.projectId == nil)
        #expect(restored.recurrence == nil && restored.recurrenceSeriesId == nil && restored.recurrenceDate == nil)
        #expect(restored.deletedAt == nil)
        #expect(try db.pendingWrites().first?.op == .put)
    }

    @Test func deleteUndoRefusesToReplaceAnAlreadyRestoredLiveTask() throws {
        let db = try store()
        let snapshot = Fixtures.task(id: "task")
        var live = snapshot
        live.title = "Already restored elsewhere"
        try db.apply(SyncResponse(cursor: "changed", tasks: [live]))
        #expect(throws: (any Error).self) { try db.restoreTask(snapshot) }
        #expect(try db.task(id: snapshot.id) == live)
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func deletingRepeatingTaskImmediatelyRemovesFutureOccurrencesButKeepsHistory() throws {
        let db = try store()
        var selected = Fixtures.task(id: "selected")
        selected.recurrence = TaskRecurrence(frequency: .week, timeZone: "UTC", startDate: "2026-11-09")
        selected.recurrenceSeriesId = "series"
        selected.recurrenceDate = "2026-11-09"
        var future = selected
        future.id = "future"
        future.recurrenceDate = "2026-11-16"
        var past = selected
        past.id = "past"
        past.recurrenceDate = "2026-11-02"
        var history = past
        history.id = "history"
        history.completedAt = Fixtures.t0
        try db.apply(SyncResponse(cursor: "initial", tasks: [selected, future, past, history]))
        try db.deleteTask(id: selected.id, now: Fixtures.t0)
        #expect(try db.openTasks().map(\.id) == ["past"])
        #expect(try db.task(id: history.id) == history)
        #expect(try db.task(id: past.id)?.recurrence == nil)
        #expect(try db.pendingWrites().map(\.entityId) == [selected.id])
    }

    private func body(_ db: AppDatabase) throws -> [String: Any] {
        let data = try #require(try db.pendingWrites().first?.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
