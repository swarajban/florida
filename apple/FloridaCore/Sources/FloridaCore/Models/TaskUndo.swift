import Foundation

public struct TaskUndo: Equatable, Sendable {
    private let before: TaskItem
    private let after: TaskItem

    public var taskId: String { before.id }
    public var deleted: TaskItem? { before.deletedAt == nil && after.deletedAt != nil ? before : nil }

    public init?(from before: TaskItem, to after: TaskItem) {
        guard before.id == after.id else { return nil }
        self.before = before
        self.after = after
        guard changedFields(in: after).reverted != after else { return nil }
    }

    public func stillApplies(to task: TaskItem) -> Bool {
        task.id == taskId && Self.same(task.completedAt, after.completedAt)
            && (task.deletedAt == nil) == (after.deletedAt == nil)
            && changedFields(in: task).matches
    }

    public func reverted(_ task: TaskItem) -> TaskItem {
        changedFields(in: task).reverted
    }

    private func changedFields(in task: TaskItem) -> (matches: Bool, reverted: TaskItem) {
        var reverted = task
        var matches = true
        func track<Value: Equatable>(
            _ path: WritableKeyPath<TaskItem, Value>, isSame: (Value, Value) -> Bool = { $0 == $1 }
        ) {
            let old = before[keyPath: path]
            let new = after[keyPath: path]
            guard !isSame(old, new) else { return }
            if !isSame(task[keyPath: path], new) { matches = false }
            reverted[keyPath: path] = old
        }
        track(\.categoryId)
        track(\.title)
        track(\.notes)
        track(\.source)
        track(\.durationMinutes)
        track(\.minChunkMinutes)
        track(\.priority)
        track(\.deadlineType)
        track(\.dueAt, isSame: Self.same)
        track(\.startAt, isSame: Self.same)
        track(\.scheduleId)
        track(\.context)
        track(\.projectId)
        track(\.attention)
        track(\.pinnedStart, isSame: Self.same)
        track(\.completedMinutes)
        track(\.completedAt, isSame: Self.same)
        track(\.recurrence)
        track(\.deletedAt) { ($0 == nil) == ($1 == nil) }
        return (matches, reverted)
    }

    public static func same(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): abs(a.timeIntervalSince(b)) < 1
        default: false
        }
    }
}
