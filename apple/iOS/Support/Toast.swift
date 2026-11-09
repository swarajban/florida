import FloridaKit
import Foundation

/// The short message at the bottom of the screen after a row action: "Completed …" with Undo,
/// or a local write that failed.
struct Toast: Identifiable, Equatable {
    enum Style: Equatable {
        case info, success, error
    }

    let id = UUID()
    var message: String
    var systemImage: String
    var style: Style
    /// What Undo puts back; no Undo button when nil.
    var undo: TaskUndo?
    /// Ghost blocks the action added, which Undo removes.
    var ghostIds: [String] = []
}

/// The fields one row action changed on a task, each with its value before and after. Undo
/// re-reads the row and puts a field back only while it still holds the value the action set, so
/// an edit made since (here or on another device) to that field or any other is never overwritten.
struct TaskUndo: Equatable {
    enum Change: Equatable {
        case completedAt(from: Date?, to: Date?)
        case completedMinutes(from: Int, to: Int)
        case deletedAt(from: Date?, to: Date?)
        case categoryId(from: String, to: String)
        case pinnedStart(from: Date?, to: Date?)
        case startAt(from: Date?, to: Date?)
    }

    var taskId: String
    var changes: [Change]
    /// For a delete: the row as it was. Pulling the pushed tombstone removes the local row, so
    /// this is what Undo saves back (live) when the row is gone; see `AppModel.undo`.
    var deleted: TaskItem?

    /// The differences between `before` and `after` among the fields row actions touch; nil when
    /// there are none.
    init?(from before: TaskItem, to after: TaskItem) {
        var changes: [Change] = []
        if !Self.same(before.completedAt, after.completedAt) {
            changes.append(.completedAt(from: before.completedAt, to: after.completedAt))
        }
        if before.completedMinutes != after.completedMinutes {
            changes.append(.completedMinutes(from: before.completedMinutes, to: after.completedMinutes))
        }
        if !Self.same(before.deletedAt, after.deletedAt) {
            changes.append(.deletedAt(from: before.deletedAt, to: after.deletedAt))
        }
        if before.categoryId != after.categoryId {
            changes.append(.categoryId(from: before.categoryId, to: after.categoryId))
        }
        if !Self.same(before.pinnedStart, after.pinnedStart) {
            changes.append(.pinnedStart(from: before.pinnedStart, to: after.pinnedStart))
        }
        if !Self.same(before.startAt, after.startAt) {
            changes.append(.startAt(from: before.startAt, to: after.startAt))
        }
        guard !changes.isEmpty else { return nil }
        taskId = before.id
        self.changes = changes
        deleted = before.deletedAt == nil && after.deletedAt != nil ? before : nil
    }

    /// Whether every changed field still holds the value the action set.
    func stillApplies(to task: TaskItem) -> Bool {
        changes.allSatisfy { change in
            switch change {
            case .completedAt(_, let to): Self.same(task.completedAt, to)
            case .completedMinutes(_, let to): task.completedMinutes == to
            // The server stamps its own tombstone time, so only deleted-or-not can be compared.
            case .deletedAt(_, let to): (task.deletedAt == nil) == (to == nil)
            case .categoryId(_, let to): task.categoryId == to
            case .pinnedStart(_, let to): Self.same(task.pinnedStart, to)
            case .startAt(_, let to): Self.same(task.startAt, to)
            }
        }
    }

    /// `task` with the changed fields back at their old values; nothing else is touched.
    func reverted(_ task: TaskItem) -> TaskItem {
        var task = task
        for change in changes {
            switch change {
            case .completedAt(let from, _): task.completedAt = from
            case .completedMinutes(let from, _): task.completedMinutes = from
            case .deletedAt(let from, _): task.deletedAt = from
            case .categoryId(let from, _): task.categoryId = from
            case .pinnedStart(let from, _): task.pinnedStart = from
            case .startAt(let from, _): task.startAt = from
            }
        }
        return task
    }

    /// Dates equal once stored and sent: the store keeps milliseconds and the server echoes what
    /// the client sent, so anything under a second apart is the same instant.
    static func same(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): abs(a.timeIntervalSince(b)) < 1
        default: false
        }
    }
}
