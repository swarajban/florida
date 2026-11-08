import FloridaKit
import SwiftUI

/// One open task in the Tasks list: priority glyph, title, duration, due date, and when the
/// scheduler put it ("Unscheduled" when it has no placements, red when it will finish late).
struct TaskRow: View {
    let task: TaskItem
    let summary: TaskScheduleSummary
    let now: Date
    let calendar: Calendar

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.priority.symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(task.priority.tint)
                .frame(width: 18)
                .padding(.top, 3)
                .accessibilityLabel(task.priority.displayName)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.body)
                HStack(spacing: 6) {
                    Text(Formatting.duration(minutes: task.durationMinutes))
                    if let dueAt = task.dueAt {
                        Text("·")
                        Label(
                            "\(task.deadlineType == .hard ? "Due" : "By") \(Formatting.dayAndTime(dueAt, now: now, calendar: calendar))",
                            systemImage: task.deadlineType == .hard ? "calendar.badge.exclamationmark" : "calendar")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                scheduleLine
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var scheduleLine: some View {
        let text = summary.text(now: now, calendar: calendar)
        switch summary.state {
        case .unscheduled:
            Label(text, systemImage: "calendar.badge.minus")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .scheduled:
            Label(text, systemImage: "calendar.badge.clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .late:
            Label("Late · \(text)", systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
