import FloridaKit
import Foundation
import SwiftUI

// Categories: local-first like tasks. Inbox (`TaskCategory.inboxId`) is permanent
// and keeps its name; the server enforces the same and moves a deleted category's tasks to it.

extension AppModel {
    /// A new category after the existing ones, with the next free palette color. The server still
    /// wants a `scheduleId` on every category though the routine replaced schedules' hours, so
    /// the new one takes Inbox's.
    @discardableResult
    func createCategory(name: String, color: String? = nil, area: CategoryArea? = nil) throws -> TaskCategory {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LocalWriteError("Give the category a name.") }
        guard let scheduleId = inbox?.scheduleId ?? schedules.first?.id else {
            throw LocalWriteError("Nothing has synced yet. Sync with the server first.")
        }
        let now = Date()
        let category = TaskCategory(
            id: UUID().uuidString.lowercased(), name: name,
            color: color ?? CategoryPalette.nextColor(after: categories), area: area, scheduleId: scheduleId,
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

    /// Deletes the category and moves its live tasks, completed ones included, to Inbox at once,
    /// as the server will.
    func deleteCategory(_ category: TaskCategory) throws {
        guard !category.isInbox else { throw LocalWriteError("Inbox can't be deleted.") }
        try perform { database in
            for var task in try database.tasks(inCategory: category.id) {
                task.categoryId = TaskCategory.inboxId
                try database.saveTask(task)
            }
            try database.deleteCategory(id: category.id)
        }
    }

    /// Moves the task to another category; the toast offers Undo.
    func move(_ task: TaskItem, to category: TaskCategory) {
        let previous = storedVersion(of: task)
        guard previous.categoryId != category.id else { return }
        var moved = previous
        moved.categoryId = category.id
        var mutation: AppDatabase.TaskMutation?
        guard write({ mutation = try $0.saveTask(moved, original: previous) }),
              let mutation, let before = mutation.before else { return }
        triageSuggestions[task.id] = nil
        showToast(Toast(
            message: "Moved to \(category.name)", systemImage: "folder.fill", style: .info, undo: TaskUndo(from: before, to: mutation.after)))
    }

    // MARK: - Schedules

    /// Legacy rows the server still keeps; only the sync queue names them.
    func schedule(id: String) -> Schedule? {
        schedules.first { $0.id == id }
    }
}
