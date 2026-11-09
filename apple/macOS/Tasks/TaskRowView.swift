import FloridaKit
import SwiftUI

/// One task: priority glyph, title, then duration, due date, scheduled time and pin state, and a
/// red or orange line when it is overdue, late (with its ETA) or could not be (fully) placed.
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
    let calendar: Calendar
    let onAcceptSuggestion: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: task.priority.symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(task.priority.tint)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(DateText.duration(minutes: task.durationMinutes))
                    if let dueAt = task.dueAt {
                        Label(DateText.day(dueAt, calendar: calendar), systemImage: task.deadlineType == .hard ? "flag.fill" : "flag")
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
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(isFocused ? 0.14 : 0.08) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: isSelected && isFocused ? 1.5 : 0))
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
    }

    private var scheduleColor: Color {
        switch state.kind {
        case .unscheduled: .secondary
        case .scheduled: tint
        case .late: .orange
        }
    }
}
