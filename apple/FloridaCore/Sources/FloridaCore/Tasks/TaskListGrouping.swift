import Foundation

public struct TaskListSection: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var category: TaskCategory?
    public var tasks: [TaskItem]
    public var isInbox: Bool

    public init(id: String, title: String, category: TaskCategory?, tasks: [TaskItem], isInbox: Bool) {
        self.id = id
        self.title = title
        self.category = category
        self.tasks = tasks
        self.isInbox = isInbox
    }
}

public enum TaskListGrouping: String, CaseIterable, Sendable {
    case dueDate
    case category

    public var title: String {
        switch self {
        case .dueDate: "Due date"
        case .category: "Category"
        }
    }

    public static func inboxTasks(in tasks: [TaskItem]) -> [TaskItem] {
        tasks.filter { $0.isOpen && $0.categoryId == TaskCategory.inboxId }.sorted(by: isListedBefore)
    }

    public func sections(
        tasks: [TaskItem], categories: [TaskCategory], now: Date, calendar: Calendar
    ) -> [TaskListSection] {
        let inbox = Self.inboxTasks(in: tasks)
        let inboxIDs = Set(inbox.map(\.id))
        let remaining = tasks.filter { $0.isOpen && !inboxIDs.contains($0.id) }
        let categories = categories.filter { $0.deletedAt == nil }.inListOrder()
        let inboxCategory = categories.first { $0.isInbox }
        var sections: [TaskListSection] = []
        if inboxCategory != nil || !inbox.isEmpty {
            sections.append(TaskListSection(
                id: TaskCategory.inboxId, title: inboxCategory?.name ?? "Inbox", category: inboxCategory,
                tasks: inbox, isInbox: true
            ))
        }

        switch self {
        case .category:
            var byCategory = Dictionary(grouping: remaining, by: \.categoryId)
            for category in categories where !category.isInbox {
                sections.append(TaskListSection(
                    id: "category:\(category.id)", title: category.name, category: category,
                    tasks: (byCategory.removeValue(forKey: category.id) ?? []).sorted(by: Self.isListedBefore),
                    isInbox: false
                ))
            }
            let orphans = byCategory.values.flatMap { $0 }.sorted(by: Self.isListedBefore)
            if !orphans.isEmpty {
                sections.append(TaskListSection(
                    id: "orphans", title: "Other", category: nil, tasks: orphans, isInbox: false
                ))
            }
        case .dueDate:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            let dayAfterTomorrow = calendar.date(byAdding: .day, value: 1, to: tomorrow)!
            let nextWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.end
            let weekAfterNext = calendar.date(byAdding: .weekOfYear, value: 1, to: nextWeek)!
            let byDueDate = Dictionary(grouping: remaining) { task -> DueSection in
                let timing = TaskTiming(task: task, now: now)
                guard let due = timing.dueAt else { return .noDueDate }
                if timing.isOverdue { return .overdue }
                if due < tomorrow { return .today }
                if due < dayAfterTomorrow { return .tomorrow }
                if due < nextWeek { return .thisWeek }
                if due < weekAfterNext { return .nextWeek }
                return .later
            }
            for section in DueSection.allCases {
                guard let tasks = byDueDate[section], !tasks.isEmpty else { continue }
                sections.append(TaskListSection(
                    id: section.rawValue, title: section.title, category: nil,
                    tasks: tasks.sorted(by: Self.isListedBefore), isInbox: false
                ))
            }
        }
        return sections
    }

    private static func isListedBefore(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.dueAt != rhs.dueAt {
            guard let lhsDue = lhs.dueAt else { return false }
            guard let rhsDue = rhs.dueAt else { return true }
            return lhsDue < rhsDue
        }
        func deadlineRank(_ type: DeadlineType) -> Int {
            switch type {
            case .hard: 0
            case .soft: 1
            case .none: 2
            }
        }
        return (deadlineRank(lhs.deadlineType), lhs.priority, lhs.title.lowercased(), lhs.id)
            < (deadlineRank(rhs.deadlineType), rhs.priority, rhs.title.lowercased(), rhs.id)
    }

    private enum DueSection: String, CaseIterable {
        case overdue
        case today
        case tomorrow
        case thisWeek = "this-week"
        case nextWeek = "next-week"
        case later
        case noDueDate = "no-due-date"

        var title: String {
            switch self {
            case .overdue: "Overdue"
            case .today: "Today"
            case .tomorrow: "Tomorrow"
            case .thisWeek: "This week"
            case .nextWeek: "Next week"
            case .later: "Later"
            case .noDueDate: "No due date"
            }
        }
    }
}
