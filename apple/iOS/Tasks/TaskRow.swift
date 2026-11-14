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
    var category: TaskCategory? = nil
    var showsSourceMark = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(task.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if showsSourceMark, let source = task.source {
                        Image(systemName: source.symbolName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Has source: \(source.title)")
                            .accessibilityIdentifier("task-source-mark-\(task.id)")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    metadata(showsContext: true).fixedSize(horizontal: true, vertical: false)
                    metadata(showsContext: false)
                }
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

    private func metadata(showsContext: Bool) -> some View {
        HStack(spacing: 6) {
            if let marker = task.priority.rowMarker {
                Text(marker)
                    .fontWeight(.semibold)
                    .foregroundStyle(task.priority.tint)
                    .accessibilityLabel("\(marker) priority")
                    .layoutPriority(3)
                Text("·")
            }
            Text(Formatting.duration(minutes: task.remainingMinutes))
            if let listDate = task.dateForTaskList() {
                Text("·")
                switch listDate {
                case .due(let date):
                    let caption = "\(task.deadlineType == .hard ? "Due" : "By") \(Formatting.due(date, now: now, calendar: calendar))"
                    Label(
                        caption,
                        systemImage: task.deadlineType == .hard ? "calendar.badge.clock" : "calendar")
                        .layoutPriority(2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(caption)
                        .accessibilityIdentifier("task-list-date-\(task.id)")
                case .pinned(let date):
                    let caption = "Pinned \(Formatting.dayAndTime(date, now: now, calendar: calendar))"
                    Label(caption, systemImage: "pin.fill")
                        .layoutPriority(2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(caption)
                        .accessibilityIdentifier("task-list-date-\(task.id)")
                case .start(let date):
                    let caption = "Start \(Formatting.notBefore(date, now: now, calendar: calendar))"
                    Label(caption, systemImage: "arrow.right.to.line")
                        .layoutPriority(2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(caption)
                        .accessibilityIdentifier("task-list-date-\(task.id)")
                }
            }
            if showsContext {
                Text("·")
                Label(task.context.displayName, systemImage: task.context.symbolName)
                    .accessibilityLabel("\(task.context.displayName) context")
                    .accessibilityIdentifier("task-context-\(task.id)")
            }
            if let category { TaskCategoryChip(category: category).layoutPriority(1) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
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
