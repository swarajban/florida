import FloridaKit
import Foundation

/// One row of the day timeline: a calendar event or a scheduled task block, with a common start
/// and end so the two kinds can be merged and sorted together.
enum AgendaItem: Identifiable, Hashable {
    case event(CalendarEvent)
    case block(ScheduledBlock)

    var id: String {
        switch self {
        case .event(let event): "event-\(event.id)"
        case .block(let block): "block-\(block.placement.id)"
        }
    }

    var start: Date {
        switch self {
        case .event(let event): event.startAt ?? .distantPast
        case .block(let block): block.placement.startAt
        }
    }

    var end: Date {
        switch self {
        case .event(let event): event.endAt ?? start
        case .block(let block): block.placement.endAt
        }
    }

    var title: String {
        switch self {
        case .event(let event):
            guard let summary = event.summary, !summary.isEmpty else { return "(No title)" }
            return summary
        case .block(let block):
            return block.task.title
        }
    }

    func isInProgress(at now: Date) -> Bool {
        start <= now && now < end
    }

    func isOver(at now: Date) -> Bool {
        end <= now
    }

    /// Timed events and task blocks of the day, by start then end.
    static func timed(from agenda: DayAgenda) -> [AgendaItem] {
        let events = agenda.events.filter { !$0.allDay }.map(AgendaItem.event)
        let blocks = agenda.placements.map(AgendaItem.block)
        return (events + blocks).sorted { lhs, rhs in
            lhs.start != rhs.start ? lhs.start < rhs.start : lhs.end < rhs.end
        }
    }

    /// All-day events of the day, in store order.
    static func allDay(from agenda: DayAgenda) -> [CalendarEvent] {
        agenda.events.filter(\.allDay)
    }
}

/// The timeline list contents: items plus the "now" marker slotted after the last item that
/// has already started.
enum TimelineRow: Identifiable, Hashable {
    case item(AgendaItem)
    case now

    var id: String {
        switch self {
        case .item(let item): item.id
        case .now: "now"
        }
    }

    static func rows(for items: [AgendaItem], now: Date?) -> [TimelineRow] {
        var rows = items.map(TimelineRow.item)
        guard let now else { return rows }
        let index = items.lastIndex { $0.start <= now }.map { $0 + 1 } ?? 0
        rows.insert(.now, at: index)
        return rows
    }
}
