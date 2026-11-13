import Foundation

public enum TaskListDate: Hashable, Sendable {
    case due(Date)
    case pinned(Date)
    case start(Date)

    public var date: Date {
        switch self {
        case .due(let date), .pinned(let date), .start(let date): date
        }
    }
}

extension TaskItem {
    public func dateForTaskList() -> TaskListDate? {
        guard !someday else { return nil }
        if let dueAt { return .due(dueAt) }
        if let pinnedStart { return .pinned(pinnedStart) }
        return startAt.map(TaskListDate.start)
    }
}
