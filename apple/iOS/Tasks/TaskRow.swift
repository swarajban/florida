import FloridaKit
import SwiftUI

/// One open task in the Tasks list: title, duration, due day, context, and when the scheduler put it. Only
/// an ASAP or high priority is printed. Late and overdue tasks read red; an unscheduled or partly
/// placed task says why and how much is left out.
struct TaskRow: View {
    let task: TaskItem
    let summary: TaskScheduleSummary
    let now: Date
    let calendar: Calendar

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let marker = task.priority.rowMarker {
                        Text(marker)
                            .fontWeight(.semibold)
                            .foregroundStyle(task.priority.tint)
                            .accessibilityLabel("\(marker) priority")
                        Text("·")
                    }
                    Text(Formatting.duration(minutes: task.remainingMinutes))
                    if let dueAt = task.dueAt {
                        Text("·")
                        Label(
                            "\(task.deadlineType == .hard ? "Due" : "By") \(Formatting.due(dueAt, now: now, calendar: calendar))",
                            systemImage: task.deadlineType == .hard ? "calendar.badge.clock" : "calendar")
                    }
                    Text("·")
                    Label(task.context.displayName, systemImage: task.context.symbolName)
                        .accessibilityLabel("\(task.context.displayName) context")
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
