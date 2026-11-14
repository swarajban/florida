import Foundation

public struct TaskTiming: Hashable, Sendable {
    public let dueAt: Date?
    public let isOverdue: Bool
    public let lateEnd: Date?

    public init(task: TaskItem, placements: [Placement] = [], now: Date) {
        dueAt = task.someday ? nil : task.dueAt
        isOverdue = task.isOpen && dueAt.map { $0 < now } == true
        if task.isOpen, let dueAt, let lastEnd = placements.map(\.endAt).max(), lastEnd > dueAt {
            lateEnd = lastEnd
        } else {
            lateEnd = nil
        }
    }
}
