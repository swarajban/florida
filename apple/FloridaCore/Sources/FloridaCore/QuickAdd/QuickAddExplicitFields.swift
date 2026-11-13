import Foundation

extension QuickAddDraft {
    public func applyingExplicitFields(to original: TaskItem, categoryId: String? = nil) -> TaskItem {
        var task = original
        if let categoryId { task.categoryId = categoryId }
        if let durationMinutes { task.durationMinutes = durationMinutes }
        if let priority { task.priority = priority }
        if let context { task.context = context }
        if let notes { task.notes = notes }
        if let source { task.source = source }
        if dueDateNotNeeded {
            task.dueAt = nil
            task.deadlineType = .none
        } else if let dueAt {
            task.dueAt = dueAt
            task.deadlineType = deadlineType ?? .soft
        }
        if let startAt { task.startAt = startAt }
        if let pinnedStart { task.pinnedStart = pinnedStart }
        if let recurrence {
            task.recurrence = recurrence
            task.prepareToEnableRecurrence()
        }
        return task
    }
}
