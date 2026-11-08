import FloridaKit
import SwiftUI

/// One task: priority glyph, title, then duration, due date, scheduled time and pin state.
struct TaskRowView: View {
    let task: TaskItem
    let state: TaskScheduleState
    let tint: Color
    let isSelected: Bool
    let isFocused: Bool
    let calendar: Calendar

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
                            .foregroundStyle(dueAt < Date() ? Color.red : Color.secondary)
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
            RoundedRectangle(cornerRadius: 1)
                .fill(tint)
                .frame(width: 2)
                .padding(.vertical, 8)
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
