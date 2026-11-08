import FloridaKit
import SwiftUI

/// Everything the calendar views draw for the visible days, computed once per data or navigation
/// change (`AppModel.rebuildLayout`) so the `Canvas` closures only turn frames into paths.
struct GridLayout {
    /// A timed block in one day column.
    struct Block: Identifiable, Hashable {
        enum Kind: Hashable {
            case event
            case task(pinned: Bool)
        }

        /// Placement id or event id; unique per block, unlike `item` for multi-block tasks.
        let id: String
        let item: ItemID
        let kind: Kind
        let dayIndex: Int
        let column: Int
        let columnCount: Int
        let startMinute: Int
        let endMinute: Int
        let start: Date
        let end: Date
        let title: String
        let tint: Color

        var isTask: Bool {
            if case .task = kind { return true }
            return false
        }

        var isPinned: Bool {
            if case .task(let pinned) = kind { return pinned }
            return false
        }
    }

    /// An all-day event in the strip above the grid.
    struct AllDayBlock: Identifiable, Hashable {
        let id: String
        let item: ItemID
        let row: Int
        let startDayIndex: Int
        let endDayIndex: Int
        let start: Date
        let title: String
        let tint: Color
    }

    var days: [Date] = []
    /// Timed blocks per visible day, in drawing order (by start, longer first).
    var blocksByDay: [[Block]] = []
    var allDayBlocks: [AllDayBlock] = []
    /// The all-day blocks touching each visible day.
    var allDayByDay: [[AllDayBlock]] = []
    var allDayRowCount = 0
    /// `j` / `k` order: by day, all-day first, then by start; each item once.
    var orderedItems: [ItemID] = []
    private var dayByItem: [ItemID: Date] = [:]

    /// The day an item is first drawn on, if it is visible.
    func day(of item: ItemID) -> Date? {
        dayByItem[item]
    }

    static func build(
        days: [Date], events: [CalendarEvent], placements: [Placement], tasksById: [String: TaskItem],
        categoriesById: [String: Category], calendarsById: [String: CalendarInfo], calendar: Calendar
    ) -> GridLayout {
        var layout = GridLayout()
        layout.days = days
        guard let firstDay = days.first, let lastDay = days.last else { return layout }
        let rangeEnd = DateNavigation.shift(lastDay, by: 1, calendar: calendar)

        var sources: [String: Source] = [:]
        var timed: [LayoutItem<String>] = []
        var allDay: [LayoutItem<String>] = []

        for event in events {
            guard let start = event.startAt, let end = event.endAt, end > firstDay, start < rangeEnd else { continue }
            let summary = event.summary?.trimmingCharacters(in: .whitespaces) ?? ""
            sources[event.id] = Source(
                item: .event(event.id), kind: .event, start: start, end: end,
                title: summary.isEmpty ? "(No title)" : summary,
                tint: calendarsById[event.calendarId]?.tint ?? .defaultCalendar)
            if event.allDay {
                allDay.append(LayoutItem(id: event.id, start: start, end: end))
            } else {
                timed.append(LayoutItem(id: event.id, start: start, end: end))
            }
        }
        for placement in placements {
            guard placement.endAt > firstDay, placement.startAt < rangeEnd,
                  let task = tasksById[placement.taskId]
            else { continue }
            sources[placement.id] = Source(
                item: .task(task.id), kind: .task(pinned: placement.pinned), start: placement.startAt,
                end: placement.endAt, title: task.title,
                tint: categoriesById[task.categoryId]?.tint ?? .defaultCategory)
            timed.append(LayoutItem(id: placement.id, start: placement.startAt, end: placement.endAt))
        }

        let rows = AllDayLayout.rows(allDay, days: days, calendar: calendar)
        layout.allDayRowCount = rows.count
        layout.allDayByDay = Array(repeating: [], count: days.count)
        for row in rows {
            for span in row {
                guard let source = sources[span.id] else { continue }
                let block = AllDayBlock(
                    id: span.id, item: source.item, row: span.row, startDayIndex: span.startDayIndex,
                    endDayIndex: span.endDayIndex, start: source.start, title: source.title, tint: source.tint)
                layout.allDayBlocks.append(block)
                for index in span.startDayIndex...span.endDayIndex {
                    layout.allDayByDay[index].append(block)
                }
            }
        }

        layout.blocksByDay = days.enumerated().map { index, day in
            let dayEnd = DateNavigation.shift(day, by: 1, calendar: calendar)
            let items = timed.filter { $0.start < dayEnd && $0.end > day }
            return DayLayout.layout(items, day: day, calendar: calendar).compactMap { frame in
                guard let source = sources[frame.id] else { return nil }
                return Block(
                    id: frame.id, item: source.item, kind: source.kind, dayIndex: index, column: frame.column,
                    columnCount: frame.columnCount, startMinute: frame.startMinute, endMinute: frame.endMinute,
                    start: source.start, end: source.end, title: source.title, tint: source.tint)
            }
        }

        var seen: Set<ItemID> = []
        for (index, day) in days.enumerated() {
            let starting = layout.allDayByDay[index].filter { $0.startDayIndex == index }.map(\.item)
            for item in starting + layout.blocksByDay[index].map(\.item) where seen.insert(item).inserted {
                layout.orderedItems.append(item)
                layout.dayByItem[item] = day
            }
        }
        return layout
    }

    /// What a block is made from, keyed by placement or event id while building.
    private struct Source {
        var item: ItemID
        var kind: Block.Kind
        var start: Date
        var end: Date
        var title: String
        var tint: Color
    }
}
