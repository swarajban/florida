import FloridaKit
import SwiftUI

struct TaskListRow: View {
    @Environment(AppModel.self) private var model
    let taskID: String
    let now: Date
    let sectionTitle: String
    let calendar: Calendar
    let showsCategory: Bool
    let targets: TaskActionTargets
    let onEdit: (TaskItem) -> Void
    @State private var showingDueDate = false

    var body: some View {
        if let task = model.blooming[taskID]?.task ?? model.task(id: taskID) {
            content(task)
        }
    }

    private func content(_ task: TaskItem) -> some View {
        let isBlooming = model.blooming[task.id] != nil
        let category = model.category(id: task.categoryId)
        let needsDateDecision = task.needsTriage && task.dateForTaskList() == nil && !task.someday
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button { onEdit(task) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        TaskRow(task: task, summary: summary(for: task), now: now, calendar: calendar,
                                category: showsCategory && category?.isInbox == false ? category : nil, showsSourceMark: false)
                            .strikethrough(isBlooming)
                        if needsDateDecision {
                            Text("Date decision pending")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .accessibilityIdentifier("tasks-row-\(task.id)")
                .accessibilityValue(sectionTitle)
                .accessibilityHint("Edits the task")
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
            if needsDateDecision, !isBlooming {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { dateActions(for: task) }
                    VStack(alignment: .leading, spacing: 10) { dateActions(for: task) }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .padding(.bottom, 6)
            }
        }
        .listRowBackground(BloomBackground(
            color: Color.category(model.category(id: task.categoryId)), active: isBlooming,
            tint: task.needsTriage ? Color.orange.opacity(0.07) : nil))
        .taskActions(task, targets: targets, onEdit: { onEdit(task) })
        .sheet(isPresented: $showingDueDate) { InboxDueDateSheet(task: task) }
    }

    @ViewBuilder
    private func dateActions(for task: TaskItem) -> some View {
        Button { showingDueDate = true } label: {
            Label("Set due date", systemImage: "calendar")
        }
        .accessibilityIdentifier("inbox-set-due-\(task.id)")
        Button { model.markSomeday(task) } label: {
            Label("Someday", systemImage: "tray")
        }
        .accessibilityIdentifier("inbox-someday-\(task.id)")
    }

    private func summary(for task: TaskItem) -> TaskScheduleSummary {
        TaskScheduleSummary(
            task: task, placements: model.placementsByTask[task.id] ?? [],
            unscheduled: model.unscheduledByTask[task.id], now: now)
    }
}
