import FloridaKit
import SwiftUI
import WidgetKit

/// Open task count and the first Inbox tasks, followed by tasks in due-date order.
struct TasksEntry: TimelineEntry {
    let date: Date
    let openCount: Int
    /// The first `TasksProvider.rowLimit` open tasks.
    let tasks: [WidgetTask]
    /// False when the shared store could not be opened or read.
    let available: Bool
    var calendar = Calendar.autoupdatingCurrent

    static func placeholder(at date: Date) -> TasksEntry {
        let samples: [(String, Priority)] = [("Reply to Jane", .asap), ("Draft Q4 plan", .high), ("Book flights", .medium)]
        let tasks = samples.map { title, priority in
            let task = TaskItem(
                id: title, categoryId: "", title: title, durationMinutes: 30, priority: priority,
                deadlineType: .soft, dueAt: date.addingTimeInterval(86_400), createdAt: date, updatedAt: date)
            return WidgetTask(task: task, placements: [], category: nil)
        }
        return TasksEntry(date: date, openCount: 7, tasks: tasks, available: true)
    }
}

struct TasksProvider: TimelineProvider {
    /// Enough rows for the medium family; the small family shows the first three.
    static let rowLimit = 5

    func placeholder(in context: Context) -> TasksEntry {
        TasksEntry.placeholder(at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (TasksEntry) -> Void) {
        let now = Date()
        if context.isPreview {
            completion(TasksEntry.placeholder(at: now))
            return
        }
        completion(Self.entry(at: now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TasksEntry>) -> Void) {
        let now = Date()
        let loaded = WidgetStore.taskTimeline()
        let dates = loaded?.dates(at: now) ?? [now]
        completion(Timeline(
            entries: dates.map { Self.entry(at: $0, from: loaded) },
            policy: .after(WidgetTaskTimeline.reloadDate(at: now, from: loaded))))
    }

    static func entry(at date: Date) -> TasksEntry {
        entry(at: date, from: WidgetStore.taskTimeline())
    }

    static func entry(at date: Date, from loaded: WidgetTaskTimeline?) -> TasksEntry {
        guard let loaded else {
            return TasksEntry(date: date, openCount: 0, tasks: [], available: false)
        }
        return TasksEntry(
            date: date, openCount: loaded.tasks.count, tasks: loaded.rows(limit: rowLimit, at: date),
            available: true, calendar: loaded.calendar)
    }
}

struct TasksWidget: Widget {
    let kind = "Tasks"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TasksProvider()) { entry in
            TasksWidgetView(entry: entry)
        }
        .configurationDisplayName("Tasks")
        .description("Your Inbox, then open tasks by due date.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TasksWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TasksEntry

    private var rowLimit: Int {
        family == .systemSmall ? 3 : TasksProvider.rowLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if entry.tasks.isEmpty {
                WidgetPlaceholder(available: entry.available, emptyText: "No open tasks")
            } else {
                ForEach(entry.tasks.prefix(rowLimit)) { task in
                    TasksWidgetRow(task: task, now: entry.date, showsDue: family != .systemSmall, calendar: entry.calendar)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetLinks.tasks)
        .containerBackground(.fill.tertiary, for: .widget)
        .privacySensitive()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tasks")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(entry.openCount)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
    }
}

/// Category color bar, title (heavier for ASAP and High), and the due day; the whole row turns red
/// when the task will finish late.
struct TasksWidgetRow: View {
    let task: WidgetTask
    let now: Date
    let showsDue: Bool
    let calendar: Calendar

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(task.late ? Color.red : task.tint)
                .frame(width: 3, height: 12)
            Text(task.title)
                .font(.caption.weight(task.priority == .asap || task.priority == .high ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(task.late ? Color.red : Color.primary)
            Spacer(minLength: 4)
            if showsDue, let listDate = task.listDate {
                Text(WidgetFormatting.taskDateLabel(listDate, now: now, calendar: calendar))
                    .font(.caption2)
                    .foregroundStyle(task.late ? Color.red : Color.secondary)
            }
        }
    }
}
