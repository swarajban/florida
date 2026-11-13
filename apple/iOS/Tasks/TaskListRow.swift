import FloridaKit
import SwiftUI

/// A row of the Tasks list: the task (tap to edit) with, on Inbox rows, the AI's category chip.
/// Swipe right for Done / Done for now; left for Delete, Tomorrow, Move to…; long press for all
/// of them plus Do now. A task completed a moment ago blooms in its category color, struck
/// through, until the list folds it away. The row and the chip are separate borderless buttons
/// so a tap on one never fires the other.
struct TaskListRow: View {
    @Environment(AppModel.self) private var model
    let taskID: String
    let now: Date
    let calendar: Calendar
    let showsCategory: Bool
    let targets: TaskActionTargets
    let onEdit: (TaskItem) -> Void

    var body: some View {
        if let task = model.blooming[taskID]?.task ?? model.task(id: taskID) {
            content(task)
        }
    }

    private func content(_ task: TaskItem) -> some View {
        let isBlooming = model.blooming[task.id] != nil
        let category = model.category(id: task.categoryId)
        return HStack(alignment: .center, spacing: 8) {
            Button { onEdit(task) } label: {
                TaskRow(task: task, summary: summary(for: task), now: now, calendar: calendar,
                        category: showsCategory && category?.isInbox == false ? category : nil, showsSourceMark: false)
                    .strikethrough(isBlooming)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .accessibilityHint("Edits the task")
            .accessibilityIdentifier("tasks-row-\(task.id)")
            if let source = task.source {
                TaskSourceButton(source: source, identifier: "task-source-open-\(task.id)", compact: true)
            }
            if isBlooming {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.category(model.category(id: task.categoryId)))
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            } else if let suggestion = model.triageSuggestion(for: task) {
                TriageChip(
                    category: suggestion.category, rationale: suggestion.rationale,
                    onAccept: { model.move(task, to: suggestion.category) },
                    onDismiss: { model.dismissTriageSuggestion(for: task) })
            }
        }
        .listRowBackground(BloomBackground(
            color: Color.category(model.category(id: task.categoryId)), active: isBlooming,
            tint: task.categoryId == TaskCategory.inboxId ? Color.orange.opacity(0.07) : nil))
        .taskActions(task, targets: targets, onEdit: { onEdit(task) })
    }

    private func summary(for task: TaskItem) -> TaskScheduleSummary {
        TaskScheduleSummary(
            task: task, placements: model.placementsByTask[task.id] ?? [],
            unscheduled: model.unscheduledByTask[task.id], now: now)
    }
}
