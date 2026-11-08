import FloridaKit
import Foundation

/// One row in a calendar widget: an event or a task block flattened to what the views draw.
struct WidgetBlock: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case event, task
    }

    var id: String
    var kind: Kind
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    /// The task's category color as "#RRGGBB"; nil for events and categories without a color.
    var colorHex: String?
    var pinned: Bool
    var location: String?

    init(event: CalendarEvent) {
        id = "event-\(event.id)"
        kind = .event
        if let summary = event.summary, !summary.isEmpty {
            title = summary
        } else {
            title = "(No title)"
        }
        start = event.startAt ?? .distantPast
        end = event.endAt ?? start
        allDay = event.allDay
        colorHex = nil
        pinned = false
        location = event.location
    }

    init(block: ScheduledBlock, category: TaskCategory?) {
        id = "block-\(block.placement.id)"
        kind = .task
        title = block.task.title
        start = block.placement.startAt
        end = block.placement.endAt
        allDay = false
        colorHex = category?.color
        pinned = block.placement.pinned
        location = nil
    }

    func isInProgress(at date: Date) -> Bool {
        start <= date && date < end
    }

    /// All-day rows first, then by start, then by end.
    static func byStart(_ lhs: WidgetBlock, _ rhs: WidgetBlock) -> Bool {
        if lhs.allDay != rhs.allDay { return lhs.allDay }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.end < rhs.end
    }
}

/// One row in the Tasks widget.
struct WidgetTask: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var priority: Priority
    var deadlineType: DeadlineType
    var dueAt: Date?
    /// The scheduler's last block for the task ends after its due date.
    var late: Bool
    var colorHex: String?

    init(task: TaskItem, placements: [Placement], category: TaskCategory?) {
        id = task.id
        title = task.title
        priority = task.priority
        deadlineType = task.deadlineType
        dueAt = task.dueAt
        if let dueAt = task.dueAt, let last = placements.max(by: { $0.endAt < $1.endAt }) {
            late = last.endAt > dueAt
        } else {
            late = false
        }
        colorHex = category?.color
    }
}
