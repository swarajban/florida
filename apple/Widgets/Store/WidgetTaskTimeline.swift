import FloridaKit
import Foundation

struct WidgetTaskTimeline {
    let tasks: [TaskItem]
    let categories: [TaskCategory]
    let placements: [String: [Placement]]
    let calendar: Calendar

    static func reloadDate(at now: Date, from loaded: WidgetTaskTimeline?) -> Date {
        let regular = now.addingTimeInterval(30 * 60)
        guard let calendar = loaded?.calendar else { return regular }
        let midnight = nextMidnight(after: now, calendar: calendar)
        return min(regular, midnight)
    }

    func dates(at now: Date) -> [Date] {
        let midnight = Self.nextMidnight(after: now, calendar: calendar)
        var dates: Set<Date> = [now, midnight]
        for task in tasks where task.deadlineType != .none {
            if let due = task.dueAt, due > now, due < midnight { dates.insert(due) }
        }
        return dates.sorted()
    }

    private static func nextMidnight(after date: Date, calendar: Calendar) -> Date {
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        return calendar.startOfDay(for: next)
    }

    func rows(limit: Int, at date: Date) -> [WidgetTask] {
        let byId = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        return TaskListGrouping.dueDate.sections(
            tasks: tasks, categories: categories, now: date, calendar: calendar)
            .flatMap(\.tasks).prefix(limit).map {
                WidgetTask(task: $0, placements: placements[$0.id] ?? [], category: byId[$0.categoryId], at: date)
            }
    }
}
