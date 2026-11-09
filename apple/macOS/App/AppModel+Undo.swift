import FloridaKit
import Foundation

/// One undoable task write: the fields it changed, with what they held before. `u` puts those
/// back only while the row still holds what the write set; when the task is gone or something
/// else (an edit, a sync) changed those fields since, undo writes nothing. Fields the write did
/// not touch are never written. The server's `PUT /api/tasks/:id` is an upsert that clears
/// `deletedAt` and takes `completedAt` from the body, so a restore is just another save.
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

        var taskId: String {
            switch self {
            case .revert(let id, _), .delete(let id): id
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
        var changes: [Self] = []
        func track<Value: Equatable>(
            _ keyPath: WritableKeyPath<TaskItem, Value>,
            isStillApplied: @escaping (Value, Value) -> Bool = { $0 == $1 }
        ) {
            let old = before[keyPath: keyPath]
            let new = after[keyPath: keyPath]
            guard old != new else { return }
            changes.append(Self(
                isStillApplied: { isStillApplied($0[keyPath: keyPath], new) },
                revert: { $0[keyPath: keyPath] = old }))
        }
        track(\.categoryId)
        track(\.title)
        track(\.notes)
        track(\.durationMinutes)
        track(\.minChunkMinutes)
        track(\.priority)
        track(\.deadlineType)
        track(\.dueAt, isStillApplied: sameInstant)
        track(\.startAt, isStillApplied: sameInstant)
        track(\.scheduleId)
        track(\.pinnedStart, isStillApplied: sameInstant)
        track(\.completedMinutes)
        track(\.completedAt, isStillApplied: sameInstant)
        track(\.recurrence)
        // Series membership and occurrence date belong to the server. Undo leaves the latest
        // metadata intact, just as completing/reopening an occurrence does.
        track(\.deletedAt) { ($0 == nil) == ($1 == nil) }
        return changes
    }

    /// Both nil, or within a second of each other.
    private static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): abs(a.timeIntervalSince(b)) < 1
        default: false
        }
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

    /// Runs `write` on task `taskId` as one undoable step: the row is read before and after, and
    /// the fields that differ are what `u` puts back; a task that did not exist before is undone
    /// by deleting it. Rethrows what `write` throws, recording nothing.
    func recordingUndo(_ label: String, taskId: String, _ write: () throws -> Void) throws {
        guard let database else { return }
        let before = try database.task(id: taskId)
        try write()
        let restore: UndoEntry.Restore
        if let before, let after = try database.task(id: taskId) {
            restore = .revert(taskId: taskId, changes: UndoEntry.FieldChange.changes(from: before, to: after))
        } else {
            restore = .delete(taskId: taskId)
        }
        undoStack.append(UndoEntry(label: label, restores: [restore], at: Date()))
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
    }

    /// `u`: puts back the fields of the last write if its rows still hold what it set; otherwise
    /// ("Already changed") nothing is written. The entry is spent either way.
    func undo() {
        guard let entry = undoStack.popLast() else {
            showGhost("Nothing to undo")
            return
        }
        guard let database else { return }
        do {
            var reverted: [TaskItem] = []
            var created: [String] = []
            for restore in entry.restores {
                switch restore {
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
                    }
                case .delete(let taskId):
                    guard let task = try database.task(id: taskId), task.deletedAt == nil else {
                        showGhost("Already changed")
                        return
                    }
                    created.append(taskId)
                }
            }
            for task in reverted {
                try database.saveTask(task)
            }
            for taskId in created {
                try database.deleteTask(id: taskId)
            }
            if let task = reverted.first, task.isOpen {
                selection = .task(task.id)
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
