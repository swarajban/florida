import Foundation
import Testing
@testable import FloridaCore

/// Monday 2026-11-09 in Los Angeles. The evening block is 20:00–23:00 PST, which is 04:00–07:00 UTC
/// on the next date, so grouping by UTC date would put every suggestion on the wrong day.
@Suite struct OptionalPicksTests {
    static let calendar = PacificTestCalendar.calendar
    static let monday = PacificTestCalendar.date(2026, 11, 9)
    static let noon = PacificTestCalendar.date(2026, 11, 9, 12)

    static func task(_ id: String, pinnedStart: Date? = nil, completedAt: Date? = nil, deletedAt: Date? = nil) -> TaskItem {
        TaskItem(
            id: id, categoryId: "personal", title: id, durationMinutes: 60, pinnedStart: pinnedStart,
            completedAt: completedAt, createdAt: noon, updatedAt: noon, deletedAt: deletedAt)
    }

    static func suggestion(_ taskId: String, block: String = "evening", day: Int = 9, from: (Int, Int), to: (Int, Int)) -> OptionalPlacement {
        OptionalPlacement(
            id: "\(block)-\(taskId)-\(day)-\(from.0)\(from.1)", taskId: taskId, blockId: block,
            startAt: PacificTestCalendar.date(2026, 11, day, from.0, from.1),
            endAt: PacificTestCalendar.date(2026, 11, day, to.0, to.1), computedAt: noon)
    }

    static func block(_ id: String, name: String) -> RoutineBlock {
        RoutineBlock(
            id: id, name: name, days: [1, 2, 3, 4], start: "20:00", end: "23:00", allows: [.computer, .home],
            optional: true, createdAt: noon, updatedAt: noon)
    }

    static func picks(
        _ placements: [OptionalPlacement], tasks: [TaskItem], blocks: [RoutineBlock] = [block("evening", name: "Evening")],
        day: Date = monday, now: Date = noon
    ) -> [OptionalPicks] {
        OptionalPicks.on(
            day: day, placements: placements, tasksById: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) }),
            blocksById: Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) }), now: now, calendar: calendar)
    }

    @Test func keepsOnlyTheLocalDaysSuggestionsInStartOrderWithTheirTotal() {
        let groups = Self.picks(
            [
                Self.suggestion("b", from: (21, 30), to: (23, 0)),
                Self.suggestion("a", from: (20, 0), to: (21, 30)),
                Self.suggestion("a", day: 10, from: (20, 0), to: (21, 0)),
            ],
            tasks: [Self.task("a"), Self.task("b")])
        #expect(groups.count == 1)
        #expect(groups.first?.id == "evening")
        #expect(groups.first?.blockName == "Evening")
        #expect(groups.first?.picks.map(\.task.id) == ["a", "b"])
        #expect(groups.first?.picks.map(\.minutes) == [90, 90])
        #expect(groups.first?.totalMinutes == 180)

        let tuesday = Self.picks(
            [Self.suggestion("a", from: (20, 0), to: (21, 30)), Self.suggestion("a", day: 10, from: (20, 0), to: (21, 0))],
            tasks: [Self.task("a")], day: PacificTestCalendar.date(2026, 11, 10, 15))
        #expect(tuesday.map(\.totalMinutes) == [60])
    }

    @Test func leavesOutTakenFinishedAndUnknownTasks() {
        let groups = Self.picks(
            [
                Self.suggestion("open", from: (20, 0), to: (20, 30)),
                Self.suggestion("pinned", from: (20, 30), to: (21, 0)),
                Self.suggestion("done", from: (21, 0), to: (21, 30)),
                Self.suggestion("deleted", from: (21, 30), to: (22, 0)),
                Self.suggestion("missing", from: (22, 0), to: (22, 30)),
            ],
            tasks: [
                Self.task("open"),
                Self.task("pinned", pinnedStart: PacificTestCalendar.date(2026, 11, 9, 20, 30)),
                Self.task("done", completedAt: Self.noon),
                Self.task("deleted", deletedAt: Self.noon),
            ])
        #expect(groups.flatMap(\.picks).map(\.task.id) == ["open"])
    }

    @Test func leavesOutSuggestionsThatHaveEndedAndDropsAnEmptyGroup() {
        let placements = [
            Self.suggestion("a", from: (20, 0), to: (21, 0)),
            Self.suggestion("b", from: (21, 0), to: (22, 0)),
        ]
        let tasks = [Self.task("a"), Self.task("b")]
        // 21:00: the first has just ended, the second is starting.
        let atNine = Self.picks(placements, tasks: tasks, now: PacificTestCalendar.date(2026, 11, 9, 21))
        #expect(atNine.flatMap(\.picks).map(\.task.id) == ["b"])
        #expect(Self.picks(placements, tasks: tasks, now: PacificTestCalendar.date(2026, 11, 9, 22)).isEmpty)
    }

    @Test func somedayDoesNotAppearInStaleSuggestions() {
        var task = Self.task("paused")
        task.someday = true
        #expect(Self.picks([Self.suggestion("paused", from: (20, 0), to: (21, 0))], tasks: [task]).isEmpty)
    }

    @Test func groupsByBlockInOrderOfFirstStartAndToleratesAnUnsyncedRoutine() {
        let groups = Self.picks(
            [
                Self.suggestion("late", from: (20, 0), to: (21, 0)),
                Self.suggestion("early", block: "dawn", from: (5, 0), to: (5, 45)),
            ],
            tasks: [Self.task("late"), Self.task("early")], now: PacificTestCalendar.date(2026, 11, 9, 4))
        #expect(groups.map(\.id) == ["dawn", "evening"])
        #expect(groups.map(\.blockName) == [nil, "Evening"])
        #expect(groups.map(\.totalMinutes) == [45, 60])
    }
}
