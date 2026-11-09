import FloridaKit
import Foundation

/// One undoable task write: the versions to put back. Every write is local-first and the server's
/// `PUT /api/tasks/:id` is an upsert that also clears `deletedAt` and takes `completedAt` from the
/// body, so undo is just another save of the previous `TaskItem` (or a delete for a new task).
struct UndoEntry {
    enum Restore {
        case save(TaskItem)
        case delete(taskId: String)

        var taskId: String {
            switch self {
            case .save(let task): task.id
            case .delete(let id): id
            }
        }
    }

    /// Past tense, shown as "Undid …": "Completed “Review doc”".
    let label: String
    let restores: [Restore]
    let at: Date
}

/// A short-lived label over the calendar confirming an action ("Pinned to Tue 2:00 PM").
struct Ghost: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let duration: Duration
}

extension AppModel {
    static let undoLimit = 50

    /// Remembers what `taskIds` looked like before a write so `u` can put it back. Call before the
    /// write; a task missing from the store records a delete (it is being created).
    func recordUndo(_ label: String, taskIds: [String]) {
        guard let database else { return }
        let restores: [UndoEntry.Restore] = taskIds.map { id in
            if let current = tasksById[id] ?? (try? database.task(id: id)) {
                return .save(current)
            }
            return .delete(taskId: id)
        }
        undoStack.append(UndoEntry(label: label, restores: restores, at: Date()))
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
    }

    /// `u`: re-saves the previous versions of the last write's tasks and selects the first.
    func undo() {
        guard let entry = undoStack.popLast() else {
            showGhost("Nothing to undo")
            return
        }
        guard let database else { return }
        do {
            for restore in entry.restores {
                switch restore {
                case .save(let task): try database.saveTask(task)
                case .delete(let id): try database.deleteTask(id: id)
                }
            }
        } catch {
            statusMessage = "Could not undo: \(error.localizedDescription)"
            return
        }
        if case .save(let task)? = entry.restores.first, task.isOpen {
            selection = .task(task.id)
        }
        showGhost("Undid: \(entry.label)")
        scheduleSync()
    }

    /// The last write if it is recent enough that "u to undo" still makes sense.
    var recentUndo: UndoEntry? {
        guard let last = undoStack.last, Date().timeIntervalSince(last.at) < 60 else { return nil }
        return last
    }

    /// Shows `text` over the calendar for `duration`, replacing any ghost already showing.
    func showGhost(_ text: String, for duration: Duration = .seconds(1)) {
        guard JoyPreferences.isOn(.ghosts) else {
            statusMessage = text
            return
        }
        let ghost = Ghost(text: text, duration: duration)
        self.ghost = ghost
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            if self?.ghost?.id == ghost.id {
                self?.ghost = nil
            }
        }
    }

    /// “Review doc”, shortened for ghosts and undo labels.
    static func quoted(_ title: String) -> String {
        let trimmed = title.count > 32 ? String(title.prefix(31)) + "…" : title
        return "“\(trimmed)”"
    }
}
