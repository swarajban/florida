import Foundation
import Testing
@testable import FloridaCore

@Suite struct TaskTimingTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-13T17:00:00Z")!

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func task(due: Date?) -> TaskItem {
        TaskItem(id: "updated", categoryId: "work", title: "Updated task", durationMinutes: 30,
                 priority: .medium, deadlineType: .soft, dueAt: due,
                 startAt: date("2026-11-17T08:00:00Z"), createdAt: now, updatedAt: now)
    }

    private func placement(start: Date, end: Date) -> Placement {
        Placement(id: "placement", taskId: "updated", startAt: start, endAt: end,
                  pinned: false, computedAt: now)
    }

    @Test func futureDueWithTheReportedStartAndPlacementIsNotOverdue() {
        let due = date("2026-11-18T07:59:59Z")
        let task = task(due: due)
        let timing = TaskTiming(task: task, placements: [placement(
            start: date("2026-11-17T20:00:00Z"), end: date("2026-11-17T20:30:00Z"))], now: now)
        #expect(timing.dueAt == due)
        #expect(!timing.isOverdue)
        #expect(timing.lateEnd == nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(TaskListGrouping.dueDate.sections(tasks: [task], categories: [], now: now,
                                                 calendar: calendar).map(\.id) == ["next-week"])
    }

    @Test func futureDueWithAnAfterDuePlacementIsLateNotOverdue() {
        let due = now.addingTimeInterval(3600)
        let end = due.addingTimeInterval(1800)
        let timing = TaskTiming(task: task(due: due), placements: [placement(start: due, end: end)], now: now)
        #expect(!timing.isOverdue)
        #expect(timing.lateEnd == end)
    }

    @Test(arguments: [-1.0, 0, 1])
    func overdueUsesTheSameStrictBoundaryAsTheSection(offset: Double) {
        let task = task(due: now.addingTimeInterval(offset))
        let timing = TaskTiming(task: task, now: now)
        #expect(timing.isOverdue == (offset < 0))
        let sections = TaskListGrouping.dueDate.sections(tasks: [task], categories: [], now: now,
                                                        calendar: Calendar(identifier: .gregorian))
        #expect((sections.first?.id == "overdue") == timing.isOverdue)
    }

    @Test func latenessUsesTheLatestEndNotTheLastStartingBlock() {
        let due = now.addingTimeInterval(3600)
        let long = placement(start: now, end: due.addingTimeInterval(600))
        var short = placement(start: now.addingTimeInterval(300), end: due.addingTimeInterval(-600))
        short.id = "short"
        let timing = TaskTiming(task: task(due: due), placements: [long, short], now: now)
        #expect(!timing.isOverdue)
        #expect(timing.lateEnd == long.endAt)
    }

    @Test func aPastDueTaskRemainsOverdueEvenWithFutureOrPreviouslyOnTimePlacements() {
        let task = task(due: now.addingTimeInterval(-3600))
        for start in [now.addingTimeInterval(-7200), now.addingTimeInterval(7200)] {
            let timing = TaskTiming(task: task, placements: [placement(
                start: start, end: start.addingTimeInterval(1800))], now: now)
            #expect(timing.isOverdue)
        }
    }

    @Test func onlyTheSavedSnapshotDrivesTheListUntilSaveOrSyncReplacesIt() {
        let saved = task(due: date("2026-11-12T07:59:59Z"))
        var draft = saved
        draft.dueAt = date("2026-11-18T07:59:59Z")
        #expect(TaskTiming(task: saved, now: now).isOverdue)
        #expect(TaskTiming(task: saved, now: now).dueAt != draft.dueAt)
        let updated = TaskTiming(task: draft, now: now)
        #expect(!updated.isOverdue)
        #expect(updated.dueAt == draft.dueAt)
    }

    @Test func absentDueAndClosedTasksHaveNoOverdueOrLateWarning() {
        #expect(!TaskTiming(task: task(due: nil), now: now).isOverdue)
        #expect(TaskTiming(task: task(due: nil), now: now).lateEnd == nil)
        var closed = task(due: now.addingTimeInterval(-3600))
        closed.completedAt = now
        #expect(!TaskTiming(task: closed, now: now).isOverdue)
        #expect(TaskTiming(task: closed, now: now).lateEnd == nil)
    }

    @Test func somedaySuppressesSavedDueAndStalePlacementTiming() {
        var paused = task(due: now.addingTimeInterval(-3600))
        paused.someday = true
        let timing = TaskTiming(task: paused, placements: [placement(
            start: now, end: now.addingTimeInterval(1800))], now: now)
        #expect(timing.dueAt == nil)
        #expect(!timing.isOverdue)
        #expect(timing.lateEnd == nil)
        #expect(TaskListGrouping.dueDate.sections(tasks: [paused], categories: [], now: now,
                                                 calendar: Calendar(identifier: .gregorian)).map(\.id) == ["someday"])
    }
}
