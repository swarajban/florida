import FloridaKit
import Foundation

/// The open tasks of one category, in `openTasks()` order. Every category gets a section, so a
/// new or emptied one is visibly there (collapsed to its header).
struct TaskSection: Identifiable {
    let id: String
    let category: TaskCategory?
    let tasks: [TaskItem]

    var title: String { category?.name ?? "No category" }
    var isInbox: Bool { category?.isInbox ?? false }

    /// The categories in list order (Inbox, work, personal, by name within each), then tasks
    /// whose category is unknown locally (deleted on another device, not synced yet).
    static func sections(categories: [TaskCategory], tasks: [TaskItem]) -> [TaskSection] {
        let grouped = Dictionary(grouping: tasks, by: \.categoryId)
        var sections = categories.inListOrder().map { category in
            TaskSection(id: category.id, category: category, tasks: grouped[category.id] ?? [])
        }
        let known = Set(categories.map(\.id))
        let orphans = tasks.filter { !known.contains($0.categoryId) }
        if !orphans.isEmpty {
            sections.append(TaskSection(id: "no-category", category: nil, tasks: orphans))
        }
        return sections
    }
}
