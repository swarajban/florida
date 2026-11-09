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
        try perform { try $0.saveTask(task) }
        return task
    }

    func save(_ task: TaskItem) throws {
        try perform { try $0.saveTask(task) }
    }

    func reopen(_ task: TaskItem) {
        write { try $0.reopenTask(id: task.id) }
    }

    /// Deletes the task and offers Undo. The server's `PUT /api/tasks/:id` clears `deletedAt`, so
    /// re-saving the old version brings it back even after the delete was pushed.
    func delete(_ task: TaskItem) {
        let previous = storedVersion(of: task)
        guard write({ try $0.deleteTask(id: task.id) }) else { return }
        showToast(Toast(message: "Deleted “\(task.title)”", systemImage: "trash.fill", style: .info, undo: [previous]))
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

    /// Puts back the task versions the toast captured.
    func undo(_ toast: Toast) {
        dismissToast()
        removeGhosts(ids: toast.ghostIds)
        write { database in
            for task in toast.undo {
                try database.saveTask(task)
            }
        }
    }
}
