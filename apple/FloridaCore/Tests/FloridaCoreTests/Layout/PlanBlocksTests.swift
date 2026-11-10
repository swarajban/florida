import Foundation
import Testing
@testable import FloridaCore

/// The week of Monday 2026-11-09 in Los Angeles.
@Suite struct PlanBlocksTests {
    static let noon = PacificTestCalendar.date(2026, 11, 9, 12)

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        PacificTestCalendar.date(2026, 11, day, hour, minute)
    }

    static func block(
        _ id: String, name: String, days: [Int], allows: [TaskContext], optional: Bool = false, deletedAt: Date? = nil
    ) -> RoutineBlock {
        RoutineBlock(
            id: id, name: name, days: days, start: "09:00", end: "17:00", allows: allows, optional: optional,
            createdAt: noon, updatedAt: noon, deletedAt: deletedAt)
    }

    static func project(
        _ id: String, name: String? = nil, status: ProjectStatus = .active, sortOrder: Int = 0, deletedAt: Date? = nil
    ) -> Project {
        Project(
            id: id, name: name ?? id, status: status, sortOrder: sortOrder, createdAt: noon, updatedAt: noon,
            deletedAt: deletedAt)
    }

    static func byId<Row: Identifiable>(_ rows: [Row]) -> [Row.ID: Row] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    // MARK: PlanBlock.join

    @Test func joinsGymAndProjectTimeInStartOrderWithTheirNames() {
        let blocks = PlanBlock.join(
            occurrences: [RoutineOccurrence(id: "o1", blockId: "gym", startAt: Self.at(10, 9), endAt: Self.at(10, 10, 15), computedAt: Self.noon)],
            projectPlacements: [
                ProjectPlacement(id: "p2", projectId: "florida", weekOf: "2026-11-09", startAt: Self.at(10, 13), endAt: Self.at(10, 14), lane: 1, computedAt: Self.noon),
                ProjectPlacement(id: "p1", projectId: "infosec", weekOf: "2026-11-09", startAt: Self.at(9, 13), endAt: Self.at(9, 15), computedAt: Self.noon),
            ],
            blocksById: Self.byId([Self.block("gym", name: "Gym", days: [2], allows: [])]),
            projectsById: Self.byId([Self.project("florida", name: "Florida"), Self.project("infosec", name: "Infosec audit")]))

        #expect(blocks.map(\.id) == ["project:infosec@1794258000", "commitment:gym@1794330000", "project:florida@1794344400"])
        #expect(blocks.map(\.title) == ["Infosec audit", "Gym", "Florida"])
        #expect(blocks.map(\.kind) == [.project(projectId: "infosec"), .commitment(blockId: "gym"), .project(projectId: "florida")])
        #expect(blocks.map(\.lane) == [nil, nil, 1])
        #expect(blocks.map(\.minutes) == [120, 75, 60])
        #expect(blocks.map(\.isCommitment) == [false, true, false])
    }

    @Test func leavesOutTimeOfAProjectThatIsNotActiveAndRowsWhoseOwnerIsGone() {
        let time = { (id: String, project: String) in
            ProjectPlacement(id: id, projectId: project, weekOf: "2026-11-09", startAt: Self.at(9, 13), endAt: Self.at(9, 14), computedAt: Self.noon)
        }
        let blocks = PlanBlock.join(
            occurrences: [
                RoutineOccurrence(id: "o1", blockId: "gone", startAt: Self.at(10, 9), endAt: Self.at(10, 10), computedAt: Self.noon),
                RoutineOccurrence(id: "o2", blockId: "deleted", startAt: Self.at(10, 9), endAt: Self.at(10, 10), computedAt: Self.noon),
            ],
            projectPlacements: [time("a", "active"), time("b", "paused"), time("c", "deleted"), time("d", "unknown")],
            blocksById: Self.byId([Self.block("deleted", name: "Gym", days: [2], allows: [], deletedAt: Self.noon)]),
            projectsById: Self.byId([
                Self.project("active"), Self.project("paused", status: .onHold), Self.project("deleted", deletedAt: Self.noon),
            ]))

        #expect(blocks.map(\.kind) == [.project(projectId: "active")])
    }

    @Test func idsStayTheSameWhenASchedulerRunReplacesTheRows() {
        // Every run gives the server's occurrence and project-time rows new random ids.
        func blocks(afterRun run: String) -> [PlanBlock] {
            PlanBlock.join(
                occurrences: [RoutineOccurrence(id: "o-\(run)", blockId: "gym", startAt: Self.at(10, 9), endAt: Self.at(10, 10, 15), computedAt: Self.noon)],
                projectPlacements: [
                    ProjectPlacement(id: "a-\(run)", projectId: "florida", weekOf: "2026-11-08", startAt: Self.at(10, 13), endAt: Self.at(10, 14), computedAt: Self.noon),
                    ProjectPlacement(id: "b-\(run)", projectId: "florida", weekOf: "2026-11-08", startAt: Self.at(11, 13), endAt: Self.at(11, 14), computedAt: Self.noon),
                ],
                blocksById: Self.byId([Self.block("gym", name: "Gym", days: [2], allows: [])]),
                projectsById: Self.byId([Self.project("florida")]))
        }

        let ids = blocks(afterRun: "first").map(\.id)
        #expect(ids == blocks(afterRun: "second").map(\.id))
        // The owner and the start, in whole seconds since 1970: 09:00 and 13:00 in Los Angeles.
        #expect(ids == ["commitment:gym@1794330000", "project:florida@1794344400", "project:florida@1794430800"])
    }

    @Test func twoRowsOfOneOwnerAtOneStartAreOneBlock() {
        // A row left behind by an earlier run must not put the same id on the grid twice.
        let time = { (id: String, endHour: Int) in
            ProjectPlacement(id: id, projectId: "florida", weekOf: "2026-11-08", startAt: Self.at(10, 13), endAt: Self.at(10, endHour), computedAt: Self.noon)
        }
        let blocks = PlanBlock.join(
            occurrences: [], projectPlacements: [time("late", 15), time("early", 14)], blocksById: [:],
            projectsById: Self.byId([Self.project("florida")]))
        #expect(blocks.map(\.id) == ["project:florida@1794344400"])
        #expect(blocks.map(\.minutes) == [60])
    }

    // MARK: ParallelWork.companions

    @Test func companionsAreTheOverlappingSpansInOtherLanesOnly() {
        let spans = [
            ParallelWork.Span(id: "a", startAt: Self.at(9, 9), endAt: Self.at(9, 11), lane: 0),
            ParallelWork.Span(id: "b", startAt: Self.at(9, 10), endAt: Self.at(9, 12), lane: 1),
            ParallelWork.Span(id: "c", startAt: Self.at(9, 10, 30), endAt: Self.at(9, 11), lane: 2),
            // Same lane as `a`, right after it: sequential, not parallel with `a`.
            ParallelWork.Span(id: "d", startAt: Self.at(9, 11), endAt: Self.at(9, 12), lane: 0),
            // Alone in the afternoon: no entry at all.
            ParallelWork.Span(id: "e", startAt: Self.at(9, 14), endAt: Self.at(9, 15), lane: 1),
        ]

        let companions = ParallelWork.companions(of: spans)

        #expect(companions["a"] == ["b", "c"])
        #expect(companions["b"] == ["a", "d", "c"])
        #expect(companions["c"] == ["a", "b"])
        #expect(companions["d"] == ["b"])
        #expect(companions["e"] == nil)
    }

    @Test func companionTitlesNameTheTasksAndProjectTimeInTheOtherLanes() {
        func task(_ id: String, _ title: String) -> TaskItem {
            TaskItem(
                id: id, categoryId: "inbox", title: title, durationMinutes: 60, priority: .medium,
                deadlineType: .none, createdAt: Self.noon, updatedAt: Self.noon)
        }
        func placement(_ id: String, _ taskId: String, _ startHour: Int, _ endHour: Int, lane: Int?) -> Placement {
            Placement(
                id: id, taskId: taskId, startAt: Self.at(9, startHour), endAt: Self.at(9, endHour), pinned: false,
                lane: lane, computedAt: Self.noon)
        }
        let titles = ParallelWork.companionTitles(
            placements: [
                placement("a", "fix", 13, 14, lane: 0),
                placement("b", "audit", 13, 15, lane: 1),
                // Full attention, a later hour, and a finished task: none is beside anything.
                placement("c", "write", 13, 14, lane: nil),
                placement("d", "fix", 16, 17, lane: 0),
                placement("e", "done", 13, 14, lane: 2),
            ],
            tasksById: ["fix": task("fix", "Fix test"), "audit": task("audit", "Audit"), "write": task("write", "Write")],
            planBlocks: [
                PlanBlock(id: "project:v", kind: .project(projectId: "vendor"), title: "Vendor review", startAt: Self.at(9, 14), endAt: Self.at(9, 15), lane: 0),
                PlanBlock(id: "commitment:g", kind: .commitment(blockId: "gym"), title: "Gym", startAt: Self.at(9, 13), endAt: Self.at(9, 14)),
            ])
        #expect(titles == ["a": ["Audit"], "b": ["Fix test", "Vendor review"], "project:v": ["Audit"]])
    }

    @Test func companionTitlesNameATaskInChunksAndAProjectInBlocksOnce() {
        let chunked = TaskItem(
            id: "chunked", categoryId: "inbox", title: "Chunked", durationMinutes: 60, priority: .medium,
            deadlineType: .none, createdAt: Self.noon, updatedAt: Self.noon)
        let chunk = { (id: String, taskId: String, start: Int, end: Int, lane: Int) in
            Placement(
                id: id, taskId: taskId, startAt: Self.at(9, 13, start), endAt: Self.at(9, 13, end), pinned: false, lane: lane,
                computedAt: Self.noon)
        }
        let atlas = { (id: String, start: Int, end: Int) in
            PlanBlock(id: id, kind: .project(projectId: "atlas"), title: "Atlas", startAt: Self.at(9, 13, start), endAt: Self.at(9, 13, end), lane: 2)
        }
        var long = chunked
        long.id = "long"
        long.title = "Long"
        let titles = ParallelWork.companionTitles(
            placements: [chunk("wide", "long", 0, 55, 0), chunk("c1", "chunked", 0, 25, 1), chunk("c2", "chunked", 30, 55, 1)],
            tasksById: ["long": long, "chunked": chunked],
            planBlocks: [atlas("project:a1", 0, 30), atlas("project:a2", 30, 55)])
        #expect(titles["wide"] == ["Chunked", "Atlas"])
    }

    @Test func spansThatOnlyTouchAreNotCompanions() {
        let spans = [
            ParallelWork.Span(id: "a", startAt: Self.at(9, 9), endAt: Self.at(9, 10), lane: 0),
            ParallelWork.Span(id: "b", startAt: Self.at(9, 10), endAt: Self.at(9, 11), lane: 1),
        ]
        #expect(ParallelWork.companions(of: spans).isEmpty)
    }

    // MARK: DayKind.of

    static let routine = [
        block("home", name: "Work from home", days: [1, 4, 5], allows: [.computer, .home, .errand]),
        block("office", name: "Office", days: [2, 3], allows: [.computer, .office]),
        block("gym", name: "Gym", days: [2], allows: []),
        block("evening", name: "Evening", days: [1, 2, 3, 4], allows: [.computer, .home], optional: true),
    ]

    @Test func aDayIsWhatItsWeekdaysPlannedBlocksMakeIt() {
        #expect(DayKind.of(date: "2026-11-09", weekday: 1, blocks: Self.routine, overrides: []) == .home)
        #expect(DayKind.of(date: "2026-11-10", weekday: 2, blocks: Self.routine, overrides: []) == .office)
        // Saturday has no blocks; Sunday here only gets an optional one, which is not planned time.
        #expect(DayKind.of(date: "2026-11-14", weekday: 6, blocks: Self.routine, overrides: []) == .off)
        let sundayEvening = Self.routine + [Self.block("late", name: "Late", days: [0], allows: [.computer], optional: true)]
        #expect(DayKind.of(date: "2026-11-15", weekday: 0, blocks: sundayEvening, overrides: []) == .off)
    }

    @Test func aGymOnlyDayIsOffAndADeletedBlockDoesNotCount() {
        let blocks = [
            Self.block("gym", name: "Gym", days: [6], allows: []),
            Self.block("old-office", name: "Office", days: [6], allows: [.office], deletedAt: Self.noon),
        ]
        #expect(DayKind.of(date: "2026-11-14", weekday: 6, blocks: blocks, overrides: []) == .off)
    }

    @Test func aLiveOverrideWinsAndADeletedOneDoesNot() {
        let live = DayOverride(date: "2026-11-10", kind: .home, createdAt: Self.noon, updatedAt: Self.noon)
        let cleared = DayOverride(date: "2026-11-09", kind: .off, createdAt: Self.noon, updatedAt: Self.noon, deletedAt: Self.noon)
        #expect(DayKind.of(date: "2026-11-10", weekday: 2, blocks: Self.routine, overrides: [live, cleared]) == .home)
        #expect(DayKind.of(date: "2026-11-09", weekday: 1, blocks: Self.routine, overrides: [live, cleared]) == .home)
        // Another date's override changes nothing here.
        #expect(DayKind.of(date: "2026-11-11", weekday: 3, blocks: Self.routine, overrides: [live, cleared]) == .office)
    }

    @Test func theDayKeyAndKindFollowTheCalendarsLocalDay() {
        // 23:30 on Tuesday the 10th in Los Angeles is already the 11th in UTC.
        let lateTuesday = Self.at(10, 23, 30)
        #expect(DayOverride.key(for: lateTuesday, calendar: PacificTestCalendar.calendar) == "2026-11-10")
        #expect(DayOverride.key(for: PacificTestCalendar.date(2027, 1, 3), calendar: PacificTestCalendar.calendar) == "2027-01-03")
        let off = DayOverride(date: "2026-11-10", kind: .off, createdAt: Self.noon, updatedAt: Self.noon)
        let calendar = PacificTestCalendar.calendar
        #expect(DayKind.of(day: lateTuesday, calendar: calendar, blocks: Self.routine, overrides: []) == .office)
        #expect(DayKind.of(day: lateTuesday, calendar: calendar, blocks: Self.routine, overrides: [off]) == .off)
        #expect(DayKind.of(day: Self.at(12, 8), calendar: calendar, blocks: Self.routine, overrides: [off]) == .home)
    }

    @Test func theDayKeyIsTheGregorianDateWhateverCalendarTheUserKeeps() {
        // A device set to the Buddhist calendar counts this year as 2569; the server's keys do not.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = PacificTestCalendar.calendar.timeZone
        let lateTuesday = Self.at(10, 23, 30)
        #expect(DayOverride.key(for: lateTuesday, calendar: buddhist) == "2026-11-10")
        let off = DayOverride(date: "2026-11-10", kind: .off, createdAt: Self.noon, updatedAt: Self.noon)
        #expect(DayKind.of(day: lateTuesday, calendar: buddhist, blocks: Self.routine, overrides: [off]) == .off)
    }

    // MARK: Plan summary

    @Test func missedNamesLeaveOutADeletedRoutineBlock() {
        let summary = PlanSummary(missed: [
            MissedCommitment(blockId: "gym", weekOf: "2026-11-08"), MissedCommitment(blockId: "swim", weekOf: "2026-11-08"),
        ])
        let blocks = Self.byId([
            Self.block("gym", name: "Gym", days: [2], allows: []),
            Self.block("swim", name: "Swim", days: [4], allows: [], deletedAt: Self.noon),
        ])
        #expect(summary.missedNames(inWeekOf: Self.at(10, 9), blocksById: blocks, calendar: PacificTestCalendar.calendar) == ["Gym"])
    }

    @Test func missedNamesAreForTheSundayWeekOfTheDayOnly() {
        let summary = PlanSummary(
            missed: [
                MissedCommitment(blockId: "gym", weekOf: "2026-11-08"),
                MissedCommitment(blockId: "swim", weekOf: "2026-11-15"),
                MissedCommitment(blockId: "unknown", weekOf: "2026-11-08"),
            ],
            capacity: [DayCapacity(date: "2026-11-10", freeMinutes: .init(computer: 90, errand: 30))])
        let blocks = Self.byId([
            Self.block("gym", name: "Gym", days: [2], allows: []), Self.block("swim", name: "Swim", days: [4], allows: []),
        ])
        let calendar = PacificTestCalendar.calendar

        // The test calendar's weeks start on Monday; the scheduler's start on Sunday. Saturday
        // the 14th and Sunday the 8th are both in the week of the 8th.
        #expect(summary.missedNames(inWeekOf: Self.at(14, 22), blocksById: blocks, calendar: calendar) == ["Gym"])
        #expect(summary.missedNames(inWeekOf: Self.at(8, 1), blocksById: blocks, calendar: calendar) == ["Gym"])
        #expect(summary.missedNames(inWeekOf: Self.at(15, 9), blocksById: blocks, calendar: calendar) == ["Swim"])
        #expect(summary.freeMinutes(on: Self.at(10, 23, 30), calendar: calendar)?[.computer] == 90)
        #expect(summary.freeMinutes(on: Self.at(11, 9), calendar: calendar) == nil)
    }

    // MARK: Projects list

    @Test func sectionsFollowTheListOrderAndSkipEmptyStatusesAndDeletedProjects() {
        let sections = ProjectSection.sections(of: [
            Self.project("z", name: "zebra", status: .active, sortOrder: 1),
            Self.project("b", name: "Beta", status: .active, sortOrder: 1),
            Self.project("first", name: "Zulu", status: .active, sortOrder: 0),
            Self.project("hold", status: .onHold),
            Self.project("gone", status: .thinking, deletedAt: Self.noon),
            Self.project("shipped", status: .done),
        ])

        #expect(sections.map(\.status) == [.active, .onHold, .done])
        #expect(sections[0].projects.map(\.id) == ["first", "b", "z"])
    }

    @Test func nextStatusCyclesThroughTheListOrder() {
        #expect(ProjectStatus.active.next == .thinking)
        #expect(ProjectStatus.thinking.next == .onHold)
        #expect(ProjectStatus.onHold.next == .done)
        #expect(ProjectStatus.done.next == .active)
    }
}
