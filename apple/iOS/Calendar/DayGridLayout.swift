import FloridaKit
import SwiftUI

/// Everything the hour grid draws for its visible days, built once per data change by
/// `DayGridView` from the days' agendas (`AppModel.gridDays`), so the views only turn frames into
/// positions. Column packing comes from `DayLayout` (with parallel work put in lane order by
/// `LaneColumns`), the all-day rows from `AllDayLayout`; this is the iOS counterpart of the Mac's
/// `GridLayout`.
struct DayGridLayout: Equatable {
    /// What a block stands for; handed back on tap and read by the drop.
    enum Item: Hashable {
        case event(CalendarEvent)
        case task(ScheduledBlock)
        case ghost(GhostBlock)
        /// What the scheduler suggests for an optional routine block; not on the plan.
        case suggestion(OptionalPicks.Pick)
        /// A commitment (the gym) or time held for a project: on the plan, but not a task.
        case plan(PlanBlock)
    }

    /// A timed block in one day column.
    struct Block: Identifiable, Hashable {
        /// Date and source id: stable when paging, distinct on either side of midnight.
        let id: String
        let item: Item
        let dayIndex: Int
        let column: Int
        let columnCount: Int
        /// Wall-clock minutes within the column, from `DayLayout` (at least the minimum span).
        let startMinute: Int
        let endMinute: Int
        let start: Date
        let end: Date
        let title: String
        /// "9:00 AM – 10:30 AM", formatted here once rather than on every body evaluation.
        let timeText: String
        let tint: Color
        /// Events: the account hue, as `EventBar` draws it.
        let rim: Color?
        let isPinned: Bool
        /// Completed, blooming or a ghost: struck through and not movable.
        let isDone: Bool

        var isEvent: Bool {
            if case .event = item { return true }
            return false
        }

        var isGhost: Bool {
            if case .ghost = item { return true }
            return false
        }

        var isSuggestion: Bool {
            if case .suggestion = item { return true }
            return false
        }

        /// The commitment or project time the block stands for; nil for every other block.
        var planBlock: PlanBlock? {
            if case .plan(let plan) = item { return plan }
            return nil
        }

        var isPlan: Bool { planBlock != nil }

        /// Plan blocks never move: the scheduler places them.
        var canMove: Bool { !isDone && !isGhost && !isSuggestion && !isPlan }

        /// Minutes the block is drawn as in its column.
        var spanMinutes: Int { endMinute - startMinute }
    }

    /// An all-day event in the strip above the grid.
    struct AllDayBlock: Identifiable, Hashable {
        let id: String
        let event: CalendarEvent
        let row: Int
        let startDayIndex: Int
        let endDayIndex: Int
        /// Start of the local day after the event's last one; the bar dims once today is past it.
        let localEnd: Date
        let title: String
        let tint: Color
        let rim: Color?
    }

    var days: [Date] = []
    /// Every visible day's timed blocks, by day then in drawing order (by start, longer first).
    var blocks: [Block] = []
    var allDayBlocks: [AllDayBlock] = []
    var allDayRowCount = 0

    /// `agendas` are matched to `days` by their `day`, so a stale or partial set never puts a
    /// day's blocks under another day's header. Events and placements present in two agendas
    /// (crossing midnight) are laid out once. A task whose `pinnedStart` no placement honours yet
    /// (the pin is local, the scheduler has not run) is drawn as the scheduler will place it: one
    /// pinned block of its remaining minutes at `pinnedStart`. `suggestions` (optional routine
    /// blocks) are packed with the rest, so one never hides under an event added since the
    /// scheduler ran. The agendas' plan blocks (commitments and project time) are packed with the
    /// rest too; work that shares its time (a `lane` on the placement or the plan block) is
    /// drawn side by side in lane order. `projectTint` colors a project's time by project id;
    /// a commitment is drawn in ink, the color of no calendar and no category.
    static func build(
        days: [Date], agendas: [DayAgenda], ghosts: [GhostBlock], suggestions: [OptionalPicks.Pick] = [],
        blooming: Set<String>, minimumMinutes: Int, calendar: Calendar,
        eventStyle: (CalendarEvent) -> EventStyle, categoryTint: (String) -> Color,
        projectTint: (String) -> Color
    ) -> DayGridLayout {
        var layout = DayGridLayout()
        layout.days = days
        guard let firstDay = days.first, let lastDay = days.last else { return layout }
        let rangeEnd = nextDayStart(after: lastDay, calendar: calendar)
        let range = firstDay..<rangeEnd
        // All-day events are stored as UTC midnights, so they are matched by calendar date.
        let allDayRange = AllDayDate.storedRange(overlapping: range, calendar: calendar)

        var events: [CalendarEvent] = []
        var seenEvents: Set<String> = []
        var placements: [ScheduledBlock] = []
        var seenPlacements: Set<String> = []
        var planBlocks: [PlanBlock] = []
        var seenPlanBlocks: Set<String> = []
        for day in days {
            guard let agenda = agendas.first(where: { $0.day == day }) else { continue }
            for event in agenda.events where seenEvents.insert(event.id).inserted {
                events.append(event)
            }
            for block in agenda.placements where seenPlacements.insert(block.placement.id).inserted {
                placements.append(block)
            }
            for block in agenda.planBlocks where seenPlanBlocks.insert(block.id).inserted {
                planBlocks.append(block)
            }
        }

        var sources: [String: Source] = [:]
        /// The lane of each task block and plan block that has one, by source id.
        var lanes: [String: Int] = [:]
        var timed: [LayoutItem<String>] = []
        var allDay: [LayoutItem<String>] = []

        for event in events {
            guard let start = event.startAt, let end = event.endAt else { continue }
            let eventRange = event.allDay ? allDayRange : range
            guard end > eventRange.lowerBound, start < eventRange.upperBound else { continue }
            let style = eventStyle(event)
            sources[event.id] = Source(
                item: .event(event), start: start, end: end, title: title(of: event), tint: style.fill, rim: style.rim,
                isPinned: false, isDone: false)
            if event.allDay {
                allDay.append(LayoutItem(id: event.id, start: start, end: end, allDay: true))
            } else {
                timed.append(LayoutItem(id: event.id, start: start, end: end))
            }
        }

        // Tasks whose stored pin a placement already honours (to the minute).
        var honouredPins: Set<String> = []
        for block in placements {
            if let pinnedStart = block.task.pinnedStart, abs(block.placement.startAt.timeIntervalSince(pinnedStart)) < 60 {
                honouredPins.insert(block.task.id)
            }
        }
        var redirected: Set<String> = []
        for scheduled in placements {
            let task = scheduled.task
            var block = scheduled
            if let pinnedStart = task.pinnedStart, task.completedAt == nil, task.remainingMinutes > 0,
               !honouredPins.contains(task.id) {
                // Every chunk collapses into the one block the scheduler will make.
                guard redirected.insert(task.id).inserted else { continue }
                block = ScheduledBlock(
                    placement: Placement(
                        id: "pin-\(task.id)", taskId: task.id, startAt: pinnedStart,
                        endAt: pinnedStart.addingTimeInterval(Double(task.remainingMinutes) * 60), pinned: true,
                        computedAt: task.updatedAt),
                    task: task)
            }
            let placement = block.placement
            guard placement.endAt > range.lowerBound, placement.startAt < range.upperBound else { continue }
            sources[placement.id] = Source(
                item: .task(block), start: placement.startAt, end: placement.endAt, title: task.title,
                tint: categoryTint(task.categoryId), rim: nil, isPinned: placement.pinned,
                isDone: task.completedAt != nil || blooming.contains(task.id))
            timed.append(LayoutItem(id: placement.id, start: placement.startAt, end: placement.endAt))
            lanes[placement.id] = placement.lane
        }

        // `PlanBlock.id` carries a kind prefix, so it never collides with an event or placement id.
        for plan in planBlocks {
            guard plan.endAt > range.lowerBound, plan.startAt < range.upperBound else { continue }
            let tint: Color
            switch plan.kind {
            case .commitment: tint = FloridaStyle.ink
            case .project(let projectId): tint = projectTint(projectId)
            }
            sources[plan.id] = Source(
                item: .plan(plan), start: plan.startAt, end: plan.endAt, title: plan.title, tint: tint, rim: nil,
                isPinned: false, isDone: false)
            timed.append(LayoutItem(id: plan.id, start: plan.startAt, end: plan.endAt))
            lanes[plan.id] = plan.lane
        }

        // Completions come from synced task timestamps, not the task's former scheduled slot.
        let completed = agendas.flatMap(\.completedTasks)
        let completedIDs = Set(completed.map(\.id))
        let visibleGhosts = ghosts.filter { !completedIDs.contains($0.taskId) } + completed.compactMap(GhostBlock.completion)
        // A partial-work ghost whose placement is still live is drawn once, as the placement.
        for ghost in visibleGhosts {
            let id = "ghost-\(ghost.id)"
            guard ghost.end > range.lowerBound, ghost.start < range.upperBound, sources[ghost.id] == nil else { continue }
            sources[id] = Source(
                item: .ghost(ghost), start: ghost.start, end: ghost.end, title: ghost.title,
                tint: categoryTint(ghost.categoryId), rim: nil, isPinned: false, isDone: true)
            timed.append(LayoutItem(id: id, start: ghost.start, end: ghost.end))
        }

        for pick in suggestions {
            let placement = pick.placement
            let id = "suggestion-\(placement.id)"
            guard placement.endAt > range.lowerBound, placement.startAt < range.upperBound else { continue }
            sources[id] = Source(
                item: .suggestion(pick), start: placement.startAt, end: placement.endAt, title: pick.task.title,
                tint: categoryTint(pick.task.categoryId), rim: nil, isPinned: false, isDone: false)
            timed.append(LayoutItem(id: id, start: placement.startAt, end: placement.endAt))
        }

        let rows = AllDayLayout.rows(allDay, days: days, calendar: calendar)
        layout.allDayRowCount = rows.count
        for row in rows {
            for span in row {
                guard let source = sources[span.id], case .event(let event) = source.item else { continue }
                layout.allDayBlocks.append(AllDayBlock(
                    id: span.id, event: event, row: span.row, startDayIndex: span.startDayIndex,
                    endDayIndex: span.endDayIndex,
                    localEnd: AllDayDate.localDays(start: source.start, end: source.end, calendar: calendar).upperBound,
                    title: source.title, tint: source.tint, rim: source.rim))
            }
        }

        for (index, day) in days.enumerated() {
            let dayEnd = nextDayStart(after: day, calendar: calendar)
            let items = timed.filter { $0.start < dayEnd && $0.end > day }
            let frames = DayLayout.layout(items, day: day, calendar: calendar, minimumMinutes: minimumMinutes)
            for frame in LaneColumns.ordered(frames, lanes: lanes) {
                guard let source = sources[frame.id] else { continue }
                let timeText: String
                if case .ghost(let ghost) = source.item, let at = ghost.completedAt {
                    timeText = "Done at \(Formatting.time(at))"
                } else {
                    timeText = Formatting.timeRange(source.start, source.end)
                }
                layout.blocks.append(Block(
                    id: "\(day.timeIntervalSinceReferenceDate)-\(frame.id)", item: source.item, dayIndex: index, column: frame.column,
                    columnCount: frame.columnCount, startMinute: frame.startMinute, endMinute: frame.endMinute,
                    start: source.start, end: source.end, title: source.title,
                    timeText: timeText, tint: source.tint, rim: source.rim,
                    isPinned: source.isPinned, isDone: source.isDone))
            }
        }
        return layout
    }

    /// The instant `minute` of `day` (local midnight) stands for; 1440 is the next day's start.
    static func date(forMinute minute: Int, on day: Date, calendar: Calendar) -> Date {
        if minute >= DayLayout.minutesPerDay {
            return nextDayStart(after: day, calendar: calendar)
        }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) ?? day
    }

    /// The first instant of the day after `day`. Where DST skips midnight the day starts at
    /// 01:00 and adding a day keeps that wall-clock time; `startOfDay` lands on the first instant.
    static func nextDayStart(after day: Date, calendar: Calendar) -> Date {
        let next = DateNavigation.shift(day, by: 1, calendar: calendar)
        return calendar.startOfDay(for: next)
    }

    /// The event's summary, or "(No title)" when Google sent none.
    static func title(of event: CalendarEvent) -> String {
        let summary = event.summary?.trimmingCharacters(in: .whitespaces) ?? ""
        return summary.isEmpty ? "(No title)" : summary
    }

    /// What a block is made from, keyed by event, placement, plan block, ghost or suggestion id
    /// while building.
    private struct Source {
        var item: Item
        var start: Date
        var end: Date
        var title: String
        var tint: Color
        var rim: Color?
        var isPinned: Bool
        var isDone: Bool
    }
}
