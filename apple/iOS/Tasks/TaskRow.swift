import FloridaKit
import SwiftUI

/// One open task in the Tasks list: priority glyph, title, duration, due date, and when the
/// scheduler put it. Late and overdue tasks read red; an unscheduled or partly placed task says
/// why and how much is left out.
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
                .accessibilityLabel("\(task.priority.displayName) priority")
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(Formatting.duration(minutes: task.remainingMinutes))
                    if let dueAt = task.dueAt {
                        Text("·")
                        Label(
                            "\(task.deadlineType == .hard ? "Due" : "By") \(Formatting.dayAndTime(dueAt, now: now, calendar: calendar))",
                            systemImage: task.deadlineType == .hard ? "calendar.badge.exclamationmark" : "calendar")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Label(summary.headline(now: now, calendar: calendar), systemImage: summary.symbolName)
                    .font(.caption)
                    .foregroundStyle(scheduleStyle)
                if let detail = summary.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(summary.isAlarming ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.orange))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var scheduleStyle: AnyShapeStyle {
        if summary.isAlarming {
            return AnyShapeStyle(Color.red)
        }
        if case .unscheduled = summary.state {
            return AnyShapeStyle(.tertiary)
        }
        return AnyShapeStyle(.secondary)
    }
}
