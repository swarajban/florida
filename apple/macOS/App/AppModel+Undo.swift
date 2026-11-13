import FloridaKit
import Foundation

/// One undoable write. For a task: the fields it changed, with what they held before. `z` puts
/// those back only while the row still holds what the write set; when the task is gone or
/// something else (an edit, a sync) changed those fields since, undo writes nothing. Fields the
/// write did not touch are never written. The server's `PUT /api/tasks/:id` is an upsert that
/// clears `deletedAt` and takes `completedAt` from the body, so a restore is just another save.
/// For an event, only a move by drag: its old times go back while it still has the new ones.
struct UndoEntry {
    /// One field a write changed.
    struct FieldChange {
        /// Whether the row still holds the value the write set.
        let isStillApplied: (TaskItem) -> Bool
        /// Puts back the value from before the write.
        let revert: (inout TaskItem) -> Void
    }

    enum Restore {
        /// The write changed these fields of a task that already existed.
        case revert(taskId: String, changes: [FieldChange])
        /// The write created the task.
        case delete(taskId: String)
        case undelete(TaskItem)
        case unavailable
        /// A drag moved the event from one time to another.
        case moveEvent(eventId: String, from: DateInterval, to: DateInterval)
        /// A drag moved this instance of a repeating event, and the rest of its series with it.
        case moveEventSeries(eventId: String, from: DateInterval, to: DateInterval)

        /// The task the write was on; nil for an event.
        var taskId: String? {
            switch self {
            case .revert(let id, _), .delete(let id): id
            case .undelete(let task): task.id
            case .moveEvent, .moveEventSeries, .unavailable: nil
            }
        }
    }

    /// Past tense, shown as "Undid: …": "Completed “Review doc”".
    let label: String
    let restores: [Restore]
    let at: Date
}

extension UndoEntry.FieldChange {
    /// The fields `after` differs from `before` in, `updatedAt` aside (the store sets it on every
    /// write). Both rows come from the store, so instants compare at its millisecond precision
    /// with a second of slack for the server's echo; a tombstone only has to still be one, since
    /// the server stamps `deletedAt` itself.
    static func changes(from before: TaskItem, to after: TaskItem) -> [Self] {
        guard let undo = TaskUndo(from: before, to: after) else { return [] }
        return [Self(isStillApplied: undo.stillApplies, revert: { $0 = undo.reverted($0) })]
    }
}

/// A short-lived label over the calendar confirming an action ("Pinned to Tue 2:00 PM").
struct Ghost: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let duration: Duration
}

extension AppModel {
    static let undoLimit = 50

    @discardableResult
    func recordingUndo(_ label: String, taskId: String, _ write: () throws -> AppDatabase.TaskMutation?) throws -> Bool {
        guard let mutation = try write() else { return false }
        let restore: UndoEntry.Restore
        if let before = mutation.before {
            let changes = UndoEntry.FieldChange.changes(from: before, to: mutation.after)
            guard !changes.isEmpty else { return false }
            restore = .revert(taskId: taskId, changes: changes)
        } else {
            restore = .delete(taskId: taskId)
        }
        pushUndo(UndoEntry(label: label, restores: [restore], at: Date()))
        return true
    }

    /// Remembers a write for `z`, dropping the oldest past `undoLimit`.
    func pushUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
    }

    /// `z`: puts back the fields of the last write if its rows still hold what it set; otherwise
    /// ("Already changed") nothing is written. The entry is spent either way.
    func undo() {
        guard let entry = undoStack.popLast() else {
            showGhost("Nothing to undo")
            return
        }
        guard let database else { return }
        do {
            var reverted: [TaskItem] = []
            var taskReverts: [(String, [UndoEntry.FieldChange])] = []
            var restored: [TaskItem] = []
            var restoredOneOff = false
            var created: [String] = []
            var eventMoves: [(id: String, expected: DateInterval, restoring: DateInterval, series: Bool)] = []
            for restore in entry.restores {
                switch restore {
                case .unavailable:
                    showGhost("Cannot undo: \(entry.label)", for: .seconds(3))
                    return
                case .undelete(let snapshot):
                    if let current = try database.task(id: snapshot.id), current.deletedAt == nil {
                        showGhost("Already changed")
                        return
                    }
                    restored.append(snapshot)
                case .revert(let taskId, let changes):
                    guard var task = try database.task(id: taskId),
                          changes.allSatisfy({ $0.isStillApplied(task) })
                    else {
                        showGhost("Already changed")
                        return
                    }
                    for change in changes {
                        change.revert(&task)
                    }
                    if !changes.isEmpty {
                        reverted.append(task)
                        taskReverts.append((taskId, changes))
                    }
                case .delete(let taskId):
                    guard let task = try database.task(id: taskId), task.deletedAt == nil else {
                        showGhost("Already changed")
                        return
                    }
                    created.append(taskId)
                case .moveEvent(let eventId, let from, let to):
                    eventMoves.append((eventId, to, from, false))
                case .moveEventSeries(let eventId, let from, let to):
                    eventMoves.append((eventId, to, from, true))
                }
            }
            for (taskId, changes) in taskReverts {
                var applied = false
                try database.updateTask(id: taskId) { task in
                    guard changes.allSatisfy({ $0.isStillApplied(task) }) else { return false }
                    for change in changes { change.revert(&task) }
                    applied = true
                    return true
                }
                guard applied else {
                    showGhost("Already changed")
                    return
                }
            }
            for snapshot in restored {
                restoredOneOff = try database.restoreTask(snapshot) || restoredOneOff
            }
            for taskId in created {
                try database.deleteTask(id: taskId)
            }
            for move in eventMoves {
                guard try database.undoEventMove(id: move.id, expected: move.expected, restoring: move.restoring, series: move.series) else {
                    showGhost("Already changed")
                    return
                }
            }
            if let task = restored.first ?? reverted.first, task.isOpen {
                selection = .task(task.id)
            } else if let eventId = eventMoves.first?.id {
                selection = .event(eventId)
            }
            if restoredOneOff {
                showGhost("Restored one task only. Repeating series cannot be restored.", for: .seconds(5))
                scheduleSync()
                return
            }
        } catch {
            statusMessage = "Could not undo: \(error.localizedDescription)"
            return
        }
        showGhost("Undid: \(entry.label)")
        scheduleSync()
    }

    /// The last write if it is recent enough that a scheduler move right after it was expected.
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
