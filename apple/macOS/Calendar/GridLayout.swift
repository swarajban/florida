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
        /// Task id and block number ("abc#0"), stable across scheduler runs unlike `id`; the
        /// event id for events.
        let slotKey: String
        /// Events: a hairline rim in the account's hue, when that touch is on.
        let rim: Color?

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
    /// In-schedule minute ranges per visible day; empty in the month view or with dimming and
    /// gaps off.
    var workingByDay: [[Range<Int>]] = []
    /// Free in-schedule time per visible day, from now on.
    var gapsByDay: [[Gap]] = []
    var options = Options()
    /// False until schedules have synced; nothing is dimmed then.
    var hasSchedules = false
    /// `j` / `k` order: by day, all-day first, then by start; each item once. With a line limit
    /// (the month view) only the lines a cell shows, never the ones behind "+N more".
    var orderedItems: [ItemID] = []
    private var dayByItem: [ItemID: Date] = [:]

    /// The day an item is first drawn on, if it is visible.
    func day(of item: ItemID) -> Date? {
        dayByItem[item]
    }

    /// Minute of day where `item` first starts on `day`: -1 for all-day items, nil when the item
    /// is not drawn that day.
    func startMinute(of item: ItemID, onDay day: Date) -> Int? {
        guard let index = days.firstIndex(of: day) else { return nil }
        if allDayByDay[index].contains(where: { $0.item == item }) { return -1 }
        if let gap = gapsByDay[index].first(where: { $0.item == item }) { return gap.startMinute }
        return blocksByDay[index].first { $0.item == item }?.startMinute
    }

    /// The selectable item on `day` whose start is closest to `minute` (all-day items count as
    /// -1), so `h` / `l` keep the cursor at about the same height; nil when the day is empty.
    func nearestItem(onDay day: Date, toMinute minute: Int) -> ItemID? {
        guard let index = days.firstIndex(of: day) else { return nil }
        let selectable = Set(orderedItems)
        var best: (item: ItemID, distance: Int)?
        let allDay = allDayByDay[index].map { (item: $0.item, minute: -1) }
        let timed = blocksByDay[index].map { (item: $0.item, minute: $0.startMinute) }
        for candidate in allDay + timed where selectable.contains(candidate.item) {
            let distance = abs(candidate.minute - minute)
            if best.map({ distance < $0.distance }) ?? true {
                best = (candidate.item, distance)
            }
        }
        return best?.item
    }

    static func build(
        days: [Date], events: [CalendarEvent], placements: [Placement], tasksById: [String: TaskItem],
        categoriesById: [String: TaskCategory], calendarsById: [String: CalendarInfo], schedules: [Schedule],
        options: Options, lineLimit: Int?, now: Date, calendar: Calendar
    ) -> GridLayout {
        var layout = GridLayout()
        layout.days = days
        guard let firstDay = days.first, let lastDay = days.last else { return layout }
        let rangeEnd = DateNavigation.shift(lastDay, by: 1, calendar: calendar)
        // All-day events are stored as UTC midnights, so they are matched by calendar date.
        let allDayRange = AllDayDate.storedRange(overlapping: firstDay..<rangeEnd, calendar: calendar)

        var sources: [String: Source] = [:]
        var timed: [LayoutItem<String>] = []
        var allDay: [LayoutItem<String>] = []

        for event in events {
            guard let start = event.startAt, let end = event.endAt else { continue }
            let range = event.allDay ? allDayRange : firstDay..<rangeEnd
            guard end > range.lowerBound, start < range.upperBound else { continue }
            let summary = event.summary?.trimmingCharacters(in: .whitespaces) ?? ""
            sources[event.id] = Source(
                item: .event(event.id), kind: .event, start: start, end: end,
                title: summary.isEmpty ? "(No title)" : summary,
                tint: calendarsById[event.calendarId]?.tint ?? .defaultCalendar, slotKey: event.id,
                rim: options.accountRims ? calendarsById[event.calendarId].map { rimColor(accountId: $0.accountId) } : nil)
            if event.allDay {
                allDay.append(LayoutItem(id: event.id, start: start, end: end, allDay: true))
            } else {
                timed.append(LayoutItem(id: event.id, start: start, end: end))
            }
        }
        var blockNumbers: [String: Int] = [:]
        for placement in placements {
            let number = blockNumbers[placement.taskId, default: 0]
            blockNumbers[placement.taskId] = number + 1
            guard placement.endAt > firstDay, placement.startAt < rangeEnd,
                  let task = tasksById[placement.taskId]
            else { continue }
            sources[placement.id] = Source(
                item: .task(task.id), kind: .task(pinned: placement.pinned), start: placement.startAt,
                end: placement.endAt, title: task.title,
                tint: categoriesById[task.categoryId]?.tint ?? .defaultCategory, slotKey: "\(task.id)#\(number)",
                rim: nil)
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
                    start: source.start, end: source.end, title: source.title, tint: source.tint,
                    slotKey: source.slotKey, rim: source.rim)
            }
        }

        layout.options = options
        layout.hasSchedules = !schedules.isEmpty
        let needsHours = !schedules.isEmpty && lineLimit == nil && (options.dimsOffHours || options.freeGaps)
        layout.workingByDay = days.map { day in
            needsHours ? ScheduleHours.workingMinutes(on: day, schedules: schedules, calendar: calendar) : []
        }
        layout.gapsByDay = days.enumerated().map { index, day in
            guard needsHours, options.freeGaps else { return [] }
            let ahead = upcoming(layout.workingByDay[index], on: day, now: now, calendar: calendar)
            return gaps(dayIndex: index, day: day, working: ahead, blocks: layout.blocksByDay[index], calendar: calendar)
        }

        var seen: Set<ItemID> = []
        for (index, day) in days.enumerated() {
            let lines: [ItemID]
            if let lineLimit {
                // The month cell's lines: all-day bars touching the day, then timed blocks.
                let allDayLines = layout.allDayByDay[index].prefix(lineLimit).map(\.item)
                lines = allDayLines + layout.blocksByDay[index].prefix(max(0, lineLimit - allDayLines.count)).map(\.item)
            } else {
                let starting = layout.allDayByDay[index].filter { $0.startDayIndex == index }.map(\.item)
                lines = starting + timedLines(blocks: layout.blocksByDay[index], gaps: layout.gapsByDay[index])
            }
            for item in lines where seen.insert(item).inserted {
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
        var slotKey: String
        var rim: Color?
    }
}
