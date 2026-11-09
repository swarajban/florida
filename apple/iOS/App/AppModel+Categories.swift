import FloridaKit
import Foundation
import SwiftUI

// Categories and schedules: local-first like tasks. Inbox (`TaskCategory.inboxId`) is permanent
// and keeps its name; the server enforces the same and moves a deleted category's tasks to it.

extension AppModel {
    /// A new category after the existing ones, with the next free palette color and Inbox's
    /// schedule (the user's work hours on a fresh server) unless one is given.
    @discardableResult
    func createCategory(name: String, color: String? = nil, scheduleId: String? = nil) throws -> TaskCategory {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LocalWriteError("Give the category a name.") }
        guard let scheduleId = scheduleId ?? inbox?.scheduleId ?? schedules.first?.id else {
            throw LocalWriteError("There are no schedules yet. Sync with the server first.")
        }
        let now = Date()
        let category = TaskCategory(
            id: UUID().uuidString.lowercased(), name: name,
            color: color ?? CategoryPalette.nextColor(after: categories), scheduleId: scheduleId,
            sortOrder: (categories.map(\.sortOrder).max() ?? 0) + 1, createdAt: now, updatedAt: now)
        try perform { try $0.saveCategory(category) }
        return category
    }

    /// The category a quick-add `#hint` asked for, created from the hint ("personal-finance" →
    /// "Personal Finance").
    func createCategory(fromHint hint: String) throws -> TaskCategory {
        try createCategory(name: CategoryPalette.name(fromHint: hint))
    }

    func saveCategory(_ category: TaskCategory) throws {
        var category = category
        category.name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.name.isEmpty else { throw LocalWriteError("Give the category a name.") }
        if category.isInbox, let stored = self.category(id: category.id), stored.name != category.name {
            throw LocalWriteError("Inbox can't be renamed.")
        }
        try perform { try $0.saveCategory(category) }
    }

    /// Deletes the category and moves its open tasks to Inbox at once, as the server will.
    func deleteCategory(_ category: TaskCategory) throws {
        guard !category.isInbox else { throw LocalWriteError("Inbox can't be deleted.") }
        let moved = openTasks.filter { $0.categoryId == category.id }
        try perform { database in
            for var task in moved {
                task.categoryId = TaskCategory.inboxId
                try database.saveTask(task)
            }
            try database.deleteCategory(id: category.id)
        }
    }

    /// Reorders the categories after Inbox, which always stays first, and saves those whose
    /// `sortOrder` changed.
    func moveCategories(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = categories.filter { !$0.isInbox }
        ordered.move(fromOffsets: source, toOffset: destination)
        write { database in
            for (index, var category) in ordered.enumerated() where category.sortOrder != index + 1 {
                category.sortOrder = index + 1
                try database.saveCategory(category)
            }
        }
    }

    /// Moves the task to another category; the toast offers Undo.
    func move(_ task: TaskItem, to category: TaskCategory) {
        let previous = storedVersion(of: task)
        guard previous.categoryId != category.id else { return }
        var moved = previous
        moved.categoryId = category.id
        guard write({ try $0.saveTask(moved) }) else { return }
        triageSuggestions[task.id] = nil
        showToast(Toast(
            message: "Moved to \(category.name)", systemImage: "folder.fill", style: .info, undo: [previous]))
    }

    // MARK: - Schedules

    func schedule(id: String) -> Schedule? {
        schedules.first { $0.id == id }
    }

    /// Categories (by name) whose tasks follow this schedule.
    func categoriesUsing(scheduleId: String) -> [TaskCategory] {
        categories.filter { $0.scheduleId == scheduleId }
    }

    func saveSchedule(_ schedule: Schedule) throws {
        var schedule = schedule
        schedule.name = schedule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !schedule.name.isEmpty else { throw LocalWriteError("Give the schedule a name.") }
        guard TimeZone(identifier: schedule.timeZone) != nil else {
            throw LocalWriteError("\(schedule.timeZone) is not a time zone.")
        }
        if let problem = WeeklyHours(windows: schedule.windows).problem {
            throw LocalWriteError(problem)
        }
        try perform { try $0.saveSchedule(schedule) }
    }

    /// Refuses while a category or task still uses the schedule: their tasks would become
    /// unschedulable.
    func deleteSchedule(_ schedule: Schedule) throws {
        let users = categoriesUsing(scheduleId: schedule.id)
        if !users.isEmpty {
            let names = users.map(\.name).formatted(.list(type: .and))
            throw LocalWriteError("\(names) \(users.count == 1 ? "uses" : "use") this schedule. Pick another schedule for \(users.count == 1 ? "it" : "them") first.")
        }
        if openTasks.contains(where: { $0.scheduleId == schedule.id }) {
            throw LocalWriteError("Some tasks use this schedule directly. Change them first.")
        }
        try perform { try $0.deleteSchedule(id: schedule.id) }
    }

    /// A blank schedule: work hours on weekdays in the device's time zone.
    func newSchedule() -> Schedule {
        let now = Date()
        return Schedule(
            id: UUID().uuidString.lowercased(), name: "",
            timeZone: TimeZone.autoupdatingCurrent.identifier,
            windows: [ScheduleWindow(days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00")],
            createdAt: now, updatedAt: now)
    }
}
