import FloridaKit
import Foundation
import WidgetKit

// Local writes. Each lands in SQLite first (observation refreshes the views) and then starts a
// background sync; nothing waits on the server. Callers that can show an error in place (quick
// add, editors) use the throwing `perform`; row actions use `write`, which reports failures in
// the toast.

/// A local write that did not happen, in words for the screen it happened on.
struct LocalWriteError: LocalizedError {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

extension AppModel {
    /// Applies `change` to the store, then requests a sync. Throws `LocalWriteError`.
    func perform(_ change: (AppDatabase) throws -> Void) throws {
        guard let database else {
            throw LocalWriteError(storeError ?? "The local store is unavailable.")
        }
        do {
            try change(database)
        } catch {
            throw LocalWriteError("Could not save locally: \(error.localizedDescription)")
        }
        if JoySetting.widgetReloadOnWrite.isOn {
            WidgetCenter.shared.reloadAllTimelines()
        }
        requestSync()
    }

    /// `perform` for row actions: a failure shows as an error toast. Returns whether it succeeded.
    @discardableResult
    func write(_ change: (AppDatabase) throws -> Void) -> Bool {
        do {
            try perform(change)
            return true
        } catch {
            showToast(Toast(message: error.localizedDescription, systemImage: "exclamationmark.triangle.fill", style: .error))
            return false
        }
    }

    // MARK: - Tasks

    /// Creates a task from quick-add text with the app's defaults (30 minutes, medium priority,
    /// `category`, else the hinted category or Inbox). `category` is for a category created a
    /// moment ago, which observation has not delivered to `categories` yet.
    @discardableResult
    func createTask(from draft: QuickAddDraft, in category: TaskCategory? = nil) throws -> TaskItem {
        guard let category = category ?? QuickAddTaskBuilder.resolveCategory(hint: draft.categoryHint, in: categories) else {
            throw LocalWriteError("There are no categories yet. Connect to the server in Settings and sync first.")
        }
        let task = QuickAddTaskBuilder.makeTask(from: draft, category: category, now: Date())
        try perform { try $0.saveTask(task, original: nil) }
        return task
    }

    func save(
        _ task: TaskItem, original: TaskItem? = nil, somedayIntent: Bool? = nil, dateEdits: Set<TaskDateField> = []
    ) throws {
        var mutation: AppDatabase.TaskMutation?
        try perform { mutation = try $0.saveTask(task, original: original, somedayIntent: somedayIntent, dateEdits: dateEdits) }
        if let mutation {
            refreshTaskDateState(mutation.after)
        }
    }

    func reopen(_ task: TaskItem) {
        write { try $0.reopenTask(id: task.id) }
    }

    /// Deletes the task and offers Undo, which clears `deletedAt` again. The server's
    /// `PUT /api/tasks/:id` does the same, so it works after the delete was pushed.
    func delete(_ task: TaskItem) {
        let now = Date()
        var previous: TaskItem?
        guard write({ previous = try $0.deleteTask(id: task.id, now: now) }), let previous, previous.deletedAt == nil else { return }
        var deleted = previous
        deleted.deletedAt = now
        showToast(Toast(
            message: previous.recurrence == nil ? "Deleted “\(previous.title)”" : "Deleted “\(previous.title)”. Undo restores one task, not the repeating series.", systemImage: "trash.fill", style: .info,
            undo: TaskUndo(from: previous, to: deleted)))
    }

    /// The store's copy of the task (the row the view holds may be a moment old).
    func storedVersion(of task: TaskItem) -> TaskItem {
        (try? database?.task(id: task.id)) ?? task
    }

    // MARK: - Toast

    func showToast(_ toast: Toast) {
        self.toast = toast
        toastDismissal?.cancel()
        let id = toast.id
        let seconds: Double = toast.style == .error ? 8 : 5
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.toast?.id == id else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastDismissal?.cancel()
        toast = nil
    }

    /// Puts back the fields the toast's action changed, after re-reading the row: when the task is
    /// gone, or something else has changed those fields since, nothing is written and the toast
    /// says so. The exception is a deleted task whose row is gone, which is what pulling the
    /// pushed tombstone does: its version from before the delete is saved back, live.
    func undo(_ toast: Toast) {
        dismissToast()
        guard let undo = toast.undo else { return }
        let current: TaskItem?
        do {
            current = try database?.task(id: undo.taskId)
        } catch {
            showToast(Toast(message: "Could not undo: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill", style: .error))
            return
        }
        let alreadyChanged = Toast(message: "Already changed since; nothing to undo.", systemImage: "arrow.uturn.backward.circle", style: .info)
        if let snapshot = undo.deleted {
            guard current == nil || current?.deletedAt != nil else {
                showToast(alreadyChanged)
                return
            }
            var oneOff = false
            guard write({ oneOff = try $0.restoreTask(snapshot) }) else { return }
            removeGhosts(ids: toast.ghostIds)
            if oneOff {
                showToast(Toast(message: "Restored one task only. Repeating series cannot be restored.", systemImage: "arrow.uturn.backward.circle", style: .info))
            }
        } else if let current {
            guard undo.stillApplies(to: current) else {
                showToast(alreadyChanged)
                return
            }
            var applied = false
            guard write({ database in
                try database.updateTask(id: undo.taskId) { task in
                    guard undo.stillApplies(to: task) else { return false }
                    task = undo.reverted(task)
                    applied = true
                    return true
                }
            }) else { return }
            guard applied else {
                showToast(alreadyChanged)
                return
            }
            removeGhosts(ids: toast.ghostIds)
            triageAttempted.remove("\(current.id)\n\(current.title)")
            refreshTaskDateState(storedVersion(of: current))
        } else {
            showToast(alreadyChanged)
        }
    }
}
