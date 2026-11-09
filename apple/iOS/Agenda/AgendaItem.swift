import FloridaKit
import Foundation

/// One row of the day timeline: a calendar event, a scheduled task block, or the ghost of a
/// block finished today, with a common start and end so the kinds can be merged and sorted.
enum AgendaItem: Identifiable, Hashable {
    case event(CalendarEvent)
    case block(ScheduledBlock)
    case ghost(GhostBlock)

    var id: String {
        switch self {
        case .event(let event): "event-\(event.id)"
        case .block(let block): "block-\(block.placement.id)"
        case .ghost(let ghost): "ghost-\(ghost.id)"
        }
    }

    var start: Date {
        switch self {
        case .event(let event): event.startAt ?? .distantPast
        case .block(let block): block.placement.startAt
        case .ghost(let ghost): ghost.start
        }
    }

    var end: Date {
        switch self {
        case .event(let event): event.endAt ?? start
        case .block(let block): block.placement.endAt
        case .ghost(let ghost): ghost.end
        }
    }

    var title: String {
        switch self {
        case .event(let event):
            guard let summary = event.summary, !summary.isEmpty else { return "(No title)" }
            return summary
        case .block(let block):
            return block.task.title
        case .ghost(let ghost):
            return ghost.title
        }
    }

    func isInProgress(at now: Date) -> Bool {
        start <= now && now < end
    }

    func isOver(at now: Date) -> Bool {
        end <= now
    }

    /// Timed events, task blocks and ghosts of the day, by start then end.
    static func timed(from agenda: DayAgenda, ghosts: [GhostBlock] = []) -> [AgendaItem] {
        let events = agenda.events.filter { !$0.allDay }.map(AgendaItem.event)
        let blocks = agenda.placements.map(AgendaItem.block)
        return (events + blocks + ghosts.map(AgendaItem.ghost)).sorted { lhs, rhs in
            lhs.start != rhs.start ? lhs.start < rhs.start : lhs.end < rhs.end
        }
    }

    /// All-day events of the day, in store order.
    static func allDay(from agenda: DayAgenda) -> [CalendarEvent] {
        agenda.events.filter(\.allDay)
    }
}

/// Open time between two timeline items. On today a gap already under way starts at `now`.
struct FreeGap: Identifiable, Hashable {
    var start: Date
    var end: Date

    var id: String { "gap-\(start.timeIntervalSinceReferenceDate)" }
    var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

/// The timeline list contents: items, free gaps between them, and the "now" marker before the
/// first row that has not started yet.
enum TimelineRow: Identifiable, Hashable {
    case item(AgendaItem)
    case gap(FreeGap)
    case now

    static let minimumGapMinutes = 15

    var id: String {
        switch self {
        case .item(let item): item.id
        case .gap(let gap): gap.id
        case .now: "now"
        }
    }

    /// `now` is nil on days other than today: no marker, and every gap counts.
    static func rows(for items: [AgendaItem], now: Date?, showsGaps: Bool) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        var busyUntil: Date?
        for item in items {
            if showsGaps, let busyUntil, let gap = gap(from: busyUntil, to: item.start, now: now) {
                rows.append(.gap(gap))
            }
            rows.append(.item(item))
            busyUntil = max(busyUntil ?? item.end, item.end)
        }
        guard let now else { return rows }
        let index = rows.firstIndex { row in
            switch row {
            case .item(let item): item.start > now
            case .gap: true
            case .now: false
            }
        } ?? rows.endIndex
        rows.insert(.now, at: index)
        return rows
    }

    /// The gap from `start` to `end` when at least `minimumGapMinutes` of it is still ahead.
    static func gap(from start: Date, to end: Date, now: Date?) -> FreeGap? {
        let start = now.map { max(start, $0) } ?? start
        let gap = FreeGap(start: start, end: end)
        return gap.minutes >= minimumGapMinutes ? gap : nil
    }
}
