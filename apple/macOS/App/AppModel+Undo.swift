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
        /// A drag moved the event from one time to another.
        case moveEvent(eventId: String, from: DateInterval, to: DateInterval)
        /// A drag moved this instance of a repeating event, and the rest of its series with it.
        case moveEventSeries(eventId: String, from: DateInterval, to: DateInterval)

        /// The task the write was on; nil for an event.
        var taskId: String? {
            switch self {
            case .revert(let id, _), .delete(let id): id
            case .moveEvent, .moveEventSeries: nil
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
        track(\.context)
        track(\.projectId)
        track(\.attention)
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
    /// the fields that differ are what `z` puts back; a task that did not exist before is undone
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
        pushUndo(UndoEntry(label: label, restores: [restore], at: Date()))
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
            var created: [String] = []
            var movedBack: [CalendarEvent] = []
            var seriesBack: [(eventId: String, back: DateInterval)] = []
            /// The event if it is still where the move left it. The store keeps milliseconds: the
            /// same instant is within a second.
            func event(_ id: String, stillAt to: DateInterval) throws -> CalendarEvent? {
                guard let event = try database.event(id: id), event.deletedAt == nil,
                      let start = event.startAt, let end = event.endAt,
                      abs(start.timeIntervalSince(to.start)) < 1, abs(end.timeIntervalSince(to.end)) < 1
                else { return nil }
                return event
            }
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
                case .moveEvent(let eventId, let from, let to):
                    guard var event = try event(eventId, stillAt: to) else {
                        showGhost("Already changed")
                        return
                    }
                    event.startAt = from.start
                    event.endAt = from.end
                    movedBack.append(event)
                case .moveEventSeries(let eventId, let from, let to):
                    guard try event(eventId, stillAt: to) != nil else {
                        showGhost("Already changed")
                        return
                    }
                    seriesBack.append((eventId, from))
                }
            }
            for task in reverted {
                try database.saveTask(task)
            }
            for taskId in created {
                try database.deleteTask(id: taskId)
            }
            for event in movedBack {
                try database.saveEvent(event)
            }
            for series in seriesBack {
                try database.moveEventSeries(instanceId: series.eventId, start: series.back.start, end: series.back.end)
            }
            if let task = reverted.first, task.isOpen {
                selection = .task(task.id)
            } else if let eventId = movedBack.first?.id ?? seriesBack.first?.eventId {
                selection = .event(eventId)
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
