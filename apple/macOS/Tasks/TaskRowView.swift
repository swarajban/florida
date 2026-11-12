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
    let isSelected: Bool
    let isFocused: Bool
    /// In Inbox: drawn with a hollow, dashed edge until it is moved to a category.
    let isUntriaged: Bool
    /// The AI's suggested category, if any; clicking it (or ⇥ on the selected row) accepts it.
    let suggestion: TaskCategory?
    /// Jump mode's label for this task, shown in place of the done circle.
    let jumpLabel: String?
    let calendar: Calendar
    let onComplete: () -> Void
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
                HStack(spacing: 8) {
                    if let marker = task.priority.rowMarker {
                        Text(marker)
                            .fontWeight(.semibold)
                            .foregroundStyle(task.priority.tint)
                            .accessibilityLabel("\(marker) priority")
                    }
                    Text(DateText.duration(minutes: task.durationMinutes))
                    // The pane is narrow: the symbol alone, named on hover and to VoiceOver.
                    Image(systemName: task.context.symbolName)
                        .help("\(task.context.displayName) context")
                        .accessibilityLabel("\(task.context.displayName) context")
                    if let dueAt = task.dueAt {
                        Label(
                            DateText.due(dueAt, calendar: calendar),
                            systemImage: task.deadlineType == .hard ? "calendar.badge.clock" : "calendar")
                            .foregroundStyle(state.isOverdue ? Color.red : Color.secondary)
                    }
                    Text(state.label(calendar: calendar))
                        .foregroundStyle(scheduleColor)
                    if state.isPinned {
                        Image(systemName: "pin.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let problem = state.problem(calendar: calendar) {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(state.isOverdue ? Color.red : Color.orange)
                        .lineLimit(2)
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
        .accessibilityIdentifier("task-row-\(task.id)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var scheduleColor: Color {
        switch state.kind {
        case .unscheduled: .secondary
        case .scheduled: tint
        case .late: .orange
        }
    }
}
