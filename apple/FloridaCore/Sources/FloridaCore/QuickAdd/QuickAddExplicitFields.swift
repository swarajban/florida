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
        if someday || clearsDueAndPin {
            task.dueAt = nil
            task.pinnedStart = nil
            task.deadlineType = .none
            task.someday = someday
        }
        if !someday, let dueAt {
            task.dueAt = dueAt
            task.deadlineType = deadlineType ?? .soft
            task.someday = false
        }
        if let startAt {
            task.startAt = startAt
            if !someday { task.someday = false }
        }
        if !someday, let pinnedStart {
            task.pinnedStart = pinnedStart
            task.someday = false
        }
        if let recurrence {
            task.recurrence = recurrence
            task.prepareToEnableRecurrence()
        }
        return task
    }
}
