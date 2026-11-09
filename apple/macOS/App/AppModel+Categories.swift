import FloridaKit
import Foundation

// Categories and schedules: local-first writes like tasks (the server keeps Inbox permanent and
// moves a deleted category's tasks to Inbox), plus matching quick add's `#hint`s.

extension AppModel {
    /// Colors offered for categories, in the order new categories take them.
    static let categoryPalette = [
        "#4F46E5", "#0EA5E9", "#10B981", "#F59E0B", "#EF4444",
        "#EC4899", "#8B5CF6", "#14B8A6", "#F97316", "#64748B",
    ]

    var inboxCategory: TaskCategory? {
        categoriesById[TaskCategory.inboxId] ?? categories.first(where: \.isInbox) ?? categories.first
    }

    /// Inbox first, then the rest in `sortOrder`.
    var orderedCategories: [TaskCategory] {
        categories.filter(\.isInbox) + categories.filter { !$0.isInbox }
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

    /// Creates a category with the next unused palette color and Inbox's schedule; nil (with a
    /// status message) when there is no schedule to give it yet.
    @discardableResult
    func createCategory(name: String, color: String? = nil, scheduleId: String? = nil) -> TaskCategory? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            statusMessage = "Type a name for the category"
            return nil
        }
        guard let scheduleId = scheduleId ?? inboxCategory?.scheduleId ?? schedules.first?.id else {
            statusMessage = "No schedules yet — sync with the server first"
            return nil
        }
        let used = Set(categories.compactMap(\.color))
        let now = Date()
        let category = TaskCategory(
            id: UUID().uuidString.lowercased(), name: trimmed,
            color: color ?? Self.categoryPalette.first { !used.contains($0) } ?? Self.categoryPalette[categories.count % Self.categoryPalette.count],
            scheduleId: scheduleId, sortOrder: (categories.map(\.sortOrder).max() ?? 0) + 1,
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

    /// Reorders the categories after Inbox (which always stays first) and saves the ones whose
    /// `sortOrder` changed.
    func moveCategories(fromOffsets source: IndexSet, toOffset destination: Int) {
        let current = orderedCategories.filter { !$0.isInbox }
        // `List.onMove` semantics (SwiftUI's `move(fromOffsets:toOffset:)`, without importing it).
        var others = current.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        others.insert(contentsOf: source.map { current[$0] }, at: min(max(insertAt, 0), others.count))
        for (index, category) in others.enumerated() where category.sortOrder != index + 1 {
            var category = category
            category.sortOrder = index + 1
            save(category)
        }
    }

    func taskCount(inCategory id: String) -> Int {
        openTasks.filter { $0.categoryId == id }.count
    }

    // MARK: Schedules

    @discardableResult
    func save(_ schedule: Schedule) -> Bool {
        guard let database else { return false }
        do {
            try database.saveSchedule(schedule)
        } catch {
            statusMessage = "Could not save the schedule: \(error.localizedDescription)"
            return false
        }
        scheduleSync()
        return true
    }

    /// A new weekday 9–5 schedule in the current time zone.
    @discardableResult
    func createSchedule() -> Schedule? {
        let now = Date()
        let schedule = Schedule(
            id: UUID().uuidString.lowercased(), name: "New schedule", timeZone: TimeZone.current.identifier,
            windows: [ScheduleWindow(days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00")],
            createdAt: now, updatedAt: now)
        return save(schedule) ? schedule : nil
    }

    func deleteSchedule(_ schedule: Schedule) {
        guard let database else { return }
        guard !categories.contains(where: { $0.scheduleId == schedule.id }) else {
            statusMessage = "Move its categories to another schedule first"
            return
        }
        do {
            try database.deleteSchedule(id: schedule.id)
        } catch {
            statusMessage = "Could not delete the schedule: \(error.localizedDescription)"
            return
        }
        scheduleSync()
    }
}
