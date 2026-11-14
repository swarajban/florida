import FloridaKit
import SwiftUI

/// One task: a circle that marks it done (the mouse's Space), the title, then priority (only ASAP or High is printed), duration, due day, scheduled
/// time and pin state, and a red or orange line when it is overdue, late (with its ETA) or could
/// not be (fully) placed.
/// Inbox rows have a dashed edge and may offer the AI's category.
struct TaskRowView: View {
    let task: TaskItem
    let state: TaskScheduleState
    let tint: Color
    let category: TaskCategory?
    let showsCategory: Bool
    let isSelected: Bool
    let isFocused: Bool
    /// In Inbox: drawn with a hollow, dashed edge until it is moved to a category.
    let isUntriaged: Bool
    /// The AI's suggested category, if any; clicking it (or ⇥ on the selected row) accepts it.
    let suggestion: TaskCategory?
    /// Jump mode's label for this task, shown in place of the done circle.
    let jumpLabel: String?
    let calendar: Calendar
    let now: Date
    let onComplete: () -> Void
    let onSetDueDate: () -> Void
    let onSomeday: () -> Void
    let onAcceptSuggestion: () -> Void
    @State private var isOverDone = false

    private static let verticalPadding: CGFloat = 9
    private static let doneSize: CGFloat = 20
    /// Where the done circle, and so the jump label, sits below the row's top edge: the task pane
    /// labels a row only while this strip is on screen.
    static let jumpLabelStrip: ClosedRange<CGFloat> = verticalPadding...(verticalPadding + doneSize)

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onComplete) {
                Image(systemName: isOverDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isOverDone ? tint : Color.secondary)
                    .frame(width: Self.doneSize, height: Self.doneSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isOverDone = $0 }
            .help("Mark done (Space)")
            .accessibilityLabel("Mark done")
            .accessibilityIdentifier("task-done-\(task.id)")
            // Hidden, not removed, under a jump label: the row keeps its layout and hover state.
            .opacity(jumpLabel == nil ? 1 : 0)
            .allowsHitTesting(jumpLabel == nil)
            .overlay {
                if let jumpLabel {
                    JumpBadge(label: jumpLabel)
                        .accessibilityIdentifier("task-jump-\(task.id)")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    metadata(showsContext: true, showsSchedule: true).fixedSize(horizontal: true, vertical: false)
                    metadata(showsContext: false, showsSchedule: true).fixedSize(horizontal: true, vertical: false)
                    metadata(showsContext: false, showsSchedule: false)
                }
                if isUntriaged && task.dateForTaskList() == nil && !task.someday {
                    HStack(spacing: 10) {
                        Button(action: onSetDueDate) {
                            HStack(spacing: 3) {
                                Text("Set due date")
                                Keycap("b")
                            }
                        }
                        .accessibilityIdentifier("task-triage-date-\(task.id)")
                        Button(action: onSomeday) {
                            HStack(spacing: 3) {
                                Text("Someday")
                                Keycap("i")
                            }
                        }
                        .accessibilityIdentifier("task-triage-indefinite-\(task.id)")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let problem = state.problem(calendar: calendar, now: now) {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(state.isOverdue ? Color.red : Color.orange)
                        .lineLimit(2)
                        .accessibilityIdentifier("task-problem-\(task.id)")
                }
                if let suggestion {
                    Button(action: onAcceptSuggestion) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("\(suggestion.name)?")
                                .foregroundStyle(suggestion.tint)
                            if isSelected {
                                Text("⇥ to accept")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Move to \(suggestion.name)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Self.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? FloridaStyle.ink.opacity(isFocused ? 0.16 : 0.09) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(FloridaStyle.ink.opacity(isFocused ? 1 : 0.5), lineWidth: isSelected ? 2 : 0))
        .overlay(alignment: .leading) {
            if isUntriaged {
                RoundedRectangle(cornerRadius: 1)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 2)
                    .padding(.vertical, 8)
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(tint)
                    .frame(width: 2)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(isSelected ? "Selected task" : "Task"), \(task.title), \(isUntriaged ? "Inbox" : "Categorized")")
        .accessibilityIdentifier("task-row-\(task.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func metadata(showsContext: Bool, showsSchedule: Bool) -> some View {
        HStack(spacing: 8) {
            if let marker = task.priority.rowMarker {
                Text(marker)
                    .fontWeight(.semibold)
                    .foregroundStyle(task.priority.tint)
                    .accessibilityLabel("\(marker) priority")
            }
            Text(DateText.duration(minutes: task.durationMinutes))
            if showsContext {
                Image(systemName: task.context.symbolName)
                    .help("\(task.context.displayName) context")
                    .accessibilityLabel("\(task.context.displayName) context")
                    .accessibilityIdentifier("task-context-\(task.id)")
            }
            if let source = task.source {
                Image(systemName: source.symbolName)
                    .help("Source: \(source.title) (g s)")
                    .accessibilityLabel("Source: \(source.title)")
                    .accessibilityIdentifier("task-source-\(task.id)")
            }
            if let listDate = task.dateForTaskList() {
                Group {
                    switch listDate {
                    case .due(let date):
                        Label {
                            Text(DateText.due(date, calendar: calendar, now: now))
                                .accessibilityIdentifier("task-due-label-\(task.id)")
                        } icon: {
                            Image(systemName: task.deadlineType == .hard ? "calendar.badge.clock" : "calendar")
                        }
                        .foregroundStyle(state.isOverdue ? Color.red : Color.secondary)
                    case .pinned(let date):
                        Label("Pinned \(DateText.dayAndTime(date, calendar: calendar, now: now))", systemImage: "pin.fill")
                            .accessibilityIdentifier("task-list-date-\(task.id)")
                    case .start(let date):
                        Label("Start \(DateText.notBefore(date, calendar: calendar, now: now))", systemImage: "arrow.right.to.line")
                            .accessibilityIdentifier("task-list-date-\(task.id)")
                    }
                }
                .layoutPriority(1)
            }
            if showsSchedule || task.someday {
                Text(state.label(calendar: calendar, now: now))
                    .foregroundStyle(scheduleColor)
                    .accessibilityIdentifier("task-schedule-label-\(task.id)")
            }
            if state.isPinned { Image(systemName: "pin.fill") }
            if showsCategory, let category, !category.isInbox {
                TaskCategoryChip(category: category)
            } else if isUntriaged && (category == nil || category?.isInbox == true) {
                Label("No category", systemImage: "folder")
                    .accessibilityIdentifier("task-inbox-category-\(task.id)")
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var scheduleColor: Color {
        switch state.kind {
        case .someday, .unscheduled: .secondary
        case .scheduled: tint
        case .late: .orange
        }
    }
}
