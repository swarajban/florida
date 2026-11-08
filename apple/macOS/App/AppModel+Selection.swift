import FloridaKit
import Foundation

/// The open tasks of one category, in the task pane's display order.
struct CategoryTaskGroup: Identifiable, Hashable {
    let id: String
    let name: String
    /// Nil for tasks whose category is not in the store (yet).
    let category: Category?
    let tasks: [TaskItem]
}

extension AppModel {
    /// Open tasks grouped by category in category order; tasks keep `openTasks`' priority order.
    var taskGroups: [CategoryTaskGroup] {
        var byCategory = Dictionary(grouping: openTasks, by: \.categoryId)
        var groups: [CategoryTaskGroup] = []
        for category in categories {
            if let tasks = byCategory.removeValue(forKey: category.id) {
                groups.append(CategoryTaskGroup(id: category.id, name: category.name, category: category, tasks: tasks))
            }
        }
        let orphans = openTasks.filter { byCategory[$0.categoryId] != nil }
        if !orphans.isEmpty {
            groups.append(CategoryTaskGroup(id: "orphans", name: "Other", category: nil, tasks: orphans))
        }
        return groups
    }

    /// `j` / `k` order in the task pane.
    var orderedTaskItems: [ItemID] {
        taskGroups.flatMap { group in group.tasks.map { ItemID.task($0.id) } }
    }

    var selectedTask: TaskItem? {
        guard case .task(let id)? = selection else { return nil }
        return tasksById[id]
    }

    var selectedEvent: CalendarEvent? {
        guard case .event(let id)? = selection else { return nil }
        return events.first { $0.id == id }
    }

    func scheduleState(for task: TaskItem) -> TaskScheduleState {
        TaskScheduleState(task: task, placements: placementsByTask[task.id] ?? [])
    }

    /// Moves the selection through the focused pane's items, clamped at both ends. With nothing
    /// selected, the calendar starts at the highlighted day's first item; otherwise forward
    /// starts at the first item and backward at the last.
    func moveFocus(by delta: Int) {
        let items = focus == .tasks ? orderedTaskItems : gridLayout.orderedItems
        guard !items.isEmpty else { return }
        let index: Int
        if let selection, let current = items.firstIndex(of: selection) {
            index = min(max(current + delta, 0), items.count - 1)
        } else if focus == .calendar,
                  let first = items.firstIndex(where: { gridLayout.day(of: $0) == selectedDay }) {
            index = first
        } else {
            index = delta >= 0 ? 0 : items.count - 1
        }
        select(items[index])
    }

    /// A click in one pane: moves the focus there and selects the item.
    func select(_ item: ItemID, in panel: Panel) {
        focus = panel
        select(item)
    }

    /// Selects an item; a calendar item also moves the day cursor onto its day.
    func select(_ item: ItemID?) {
        selection = item
        if focus == .calendar, let item, let day = gridLayout.day(of: item) {
            selectedDay = day
        }
    }
}
