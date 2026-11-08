import FloridaKit
import Foundation

/// Turns a `QuickAddDraft` into a `TaskItem` with the app's defaults, and matches `#project`
/// hints against the real projects.
enum QuickAddTaskBuilder {
    static let defaultDurationMinutes = 30

    /// The project a `#hint` names, or nil when none matches. Case-insensitive; hyphens and
    /// underscores count as spaces; an exact name wins over a prefix match.
    static func matchProject(hint: String, in projects: [Project]) -> Project? {
        let needle = normalize(hint)
        guard !needle.isEmpty else { return nil }
        if let exact = projects.first(where: { normalize($0.name) == needle }) {
            return exact
        }
        return projects.first { normalize($0.name).hasPrefix(needle) }
    }

    /// `matchProject` when the hint matches; otherwise the project named "Inbox", otherwise the
    /// first project; nil only when there are no projects at all.
    static func resolveProject(hint: String?, in projects: [Project]) -> Project? {
        if let hint, let match = matchProject(hint: hint, in: projects) {
            return match
        }
        return projects.first { normalize($0.name) == "inbox" } ?? projects.first
    }

    /// A new task from the draft: 30 minutes and medium priority unless the text said otherwise,
    /// a deadline only when a date was parsed, a client-generated lowercase UUID.
    static func makeTask(from draft: QuickAddDraft, project: Project, now: Date) -> TaskItem {
        TaskItem(
            id: UUID().uuidString.lowercased(),
            projectId: project.id,
            title: draft.title,
            notes: draft.notes,
            durationMinutes: draft.durationMinutes ?? defaultDurationMinutes,
            priority: draft.priority ?? .medium,
            deadlineType: draft.dueAt == nil ? .none : (draft.deadlineType ?? .soft),
            dueAt: draft.dueAt,
            startAt: draft.startAt,
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
