import FloridaKit
import Foundation

// Categories: local-first writes like tasks (the server keeps Inbox permanent and moves a deleted
// category's tasks to Inbox), plus matching quick add's `#hint`s.

extension AppModel {
    /// Colors offered for categories, in the order new categories take them.
    static let categoryPalette = [
        "#4F46E5", "#0EA5E9", "#10B981", "#F59E0B", "#EF4444",
        "#EC4899", "#8B5CF6", "#14B8A6", "#F97316", "#64748B",
    ]

    var inboxCategory: TaskCategory? {
        categoriesById[TaskCategory.inboxId] ?? categories.first(where: \.isInbox) ?? categories.first
    }

    /// The categories as every list and picker shows them: Inbox, then work, then personal, by
    /// name within each (`TaskCategory.isListedBefore`).
    var orderedCategories: [TaskCategory] {
        categories.inListOrder()
    }

    /// Matches a `#hint` to a category name case-insensitively, treating "-" and "_" as spaces:
    /// exact match first, then prefix. Nil without a hint or a match.
    func matchCategory(hint: String?) -> TaskCategory? {
        guard let hint else { return nil }
        let wanted = Self.normalizedCategoryName(hint)
        guard !wanted.isEmpty else { return nil }
        return categories.first { Self.normalizedCategoryName($0.name) == wanted }
            ?? categories.first { Self.normalizedCategoryName($0.name).hasPrefix(wanted) }
    }

    static func normalizedCategoryName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "side-project" → "Side Project".
    static func categoryName(fromHint hint: String) -> String {
        normalizedCategoryName(hint).split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Creates a category with the next unused palette color; nil (with a status message) before
    /// the first sync. The server still wants a `scheduleId` on every category though the routine
    /// replaced schedules' hours, so the new one takes Inbox's.
    @discardableResult
    func createCategory(name: String, color: String? = nil, area: CategoryArea? = nil) -> TaskCategory? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            statusMessage = "Type a name for the category"
            return nil
        }
        guard let scheduleId = inboxCategory?.scheduleId ?? schedules.first?.id else {
            statusMessage = "Nothing has synced yet — sync with the server first"
            return nil
        }
        let used = Set(categories.compactMap(\.color))
        let now = Date()
        let category = TaskCategory(
            id: UUID().uuidString.lowercased(), name: trimmed,
            color: color ?? Self.categoryPalette.first { !used.contains($0) } ?? Self.categoryPalette[categories.count % Self.categoryPalette.count],
            area: area, scheduleId: scheduleId, sortOrder: (categories.map(\.sortOrder).max() ?? 0) + 1,
            createdAt: now, updatedAt: now)
        guard save(category) else { return nil }
        showGhost("Created \(trimmed)")
        return category
    }

    /// Upserts a category locally and syncs. Inbox keeps its name whatever the caller passes.
    @discardableResult
    func save(_ category: TaskCategory) -> Bool {
        guard let database else { return false }
        var category = category
        if category.isInbox, let stored = categoriesById[category.id] {
            category.name = stored.name
        }
        do {
            try database.saveCategory(category)
        } catch {
            statusMessage = "Could not save the category: \(error.localizedDescription)"
            return false
        }
        scheduleSync()
        return true
    }

    /// Deletes a category; the server moves its tasks to Inbox. Inbox cannot be deleted.
    func deleteCategory(_ category: TaskCategory) {
        guard !category.isInbox, let database else { return }
        do {
            try database.deleteCategory(id: category.id)
        } catch {
            statusMessage = "Could not delete the category: \(error.localizedDescription)"
            return
        }
        showGhost("Deleted \(category.name)")
        scheduleSync()
    }

    func taskCount(inCategory id: String) -> Int {
        openTasks.filter { $0.categoryId == id }.count
    }
}
