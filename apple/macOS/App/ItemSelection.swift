import Foundation

/// What the focus ring is on: one task (every placement of it lights up), one Google event, a
/// free gap, a suggestion, or a block the plan holds for the gym or a project.
enum ItemID: Hashable, Sendable {
    case task(String)
    case event(String)
    /// A free stretch of schedule time on the grid (`GridLayout.Gap.id`).
    case gap(String)
    /// What the scheduler suggests for an optional routine block (`OptionalPlacement.id`): a dotted
    /// block on the grid and, today, a row on top of the task pane. It stands for its task: task
    /// commands act on that task, and `p` pins it at the suggested start.
    case suggestion(String)
    /// The gym or project time on the grid (`PlanBlock.id`): on the plan, but nothing to edit.
    case plan(String)

    var isTask: Bool {
        if case .task = self { return true }
        return false
    }

    var isSuggestion: Bool {
        if case .suggestion = self { return true }
        return false
    }

    var isGap: Bool {
        if case .gap = self { return true }
        return false
    }
}

/// Which pane `j` / `k` move through.
enum Panel: Hashable, Sendable {
    case calendar
    case tasks
}
