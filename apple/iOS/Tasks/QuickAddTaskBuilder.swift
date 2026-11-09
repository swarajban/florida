import FloridaKit
import Foundation

/// Turns a `QuickAddDraft` into a `TaskItem` with the app's defaults, and matches `#category`
/// hints against the real categories.
enum QuickAddTaskBuilder {
    static let defaultDurationMinutes = 30

    /// The category a `#hint` names, or nil when none matches. Case-insensitive; hyphens and
    /// underscores count as spaces; an exact name wins over a prefix match.
    static func matchCategory(hint: String, in categories: [TaskCategory]) -> TaskCategory? {
        let needle = normalize(hint)
        guard !needle.isEmpty else { return nil }
        if let exact = categories.first(where: { normalize($0.name) == needle }) {
            return exact
        }
        return categories.first { normalize($0.name).hasPrefix(needle) }
    }

    /// `matchCategory` when the hint matches; otherwise Inbox, otherwise the first category; nil
    /// only when there are no categories at all.
    static func resolveCategory(hint: String?, in categories: [TaskCategory]) -> TaskCategory? {
        if let hint, let match = matchCategory(hint: hint, in: categories) {
            return match
        }
        return categories.first(where: \.isInbox) ?? categories.first
    }

    /// A new task from the draft: 30 minutes, medium priority and the computer context unless the
    /// text said otherwise, a deadline only when a date was parsed, a client-generated lowercase UUID.
    static func makeTask(from draft: QuickAddDraft, category: TaskCategory, now: Date) -> TaskItem {
        TaskItem(
            id: UUID().uuidString.lowercased(),
            categoryId: category.id,
            title: draft.title,
            notes: draft.notes,
            durationMinutes: draft.durationMinutes ?? defaultDurationMinutes,
            priority: draft.priority ?? .medium,
            deadlineType: draft.dueAt == nil ? .none : (draft.deadlineType ?? .soft),
            dueAt: draft.dueAt,
            startAt: draft.startAt,
            context: draft.context ?? .computer,
            pinnedStart: draft.pinnedStart,
            createdAt: now,
            updatedAt: now)
    }

    static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
