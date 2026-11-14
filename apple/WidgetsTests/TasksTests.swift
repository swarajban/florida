import FloridaKit
import Foundation
import Testing
#if canImport(FloridaWidgetLogic)
@testable import FloridaWidgetLogic
#endif

struct TasksTests {
    @Test func somedayIsExcludedBeforeCountingOrderingAndLimitingRows() throws {
        let now = JSONCoding.parseInstant("2026-11-12T20:00:00Z")!
        let database = try AppDatabase.inMemory()
        try database.saveSchedule(Schedule(
            id: "routine", name: "Routine", timeZone: "America/Los_Angeles", windows: [],
            createdAt: now, updatedAt: now), now: now)
        for id in [TaskCategory.inboxId, "work"] {
            try database.saveCategory(TaskCategory(
                id: id, name: id, scheduleId: "routine", createdAt: now, updatedAt: now), now: now)
        }
        let earlier = now.addingTimeInterval(-3600)
        let tasks = [
            TaskItem(id: "due", categoryId: "work", title: "Due", durationMinutes: 30,
                     dueAt: earlier, createdAt: now, updatedAt: now),
            TaskItem(id: "start", categoryId: "work", title: "Start", durationMinutes: 30,
                     startAt: now, createdAt: now, updatedAt: now),
            TaskItem(id: "pin", categoryId: "work", title: "Pin", durationMinutes: 30,
                     pinnedStart: now.addingTimeInterval(60), createdAt: now, updatedAt: now),
            TaskItem(id: "paused-inbox", categoryId: TaskCategory.inboxId, title: "Paused Inbox", durationMinutes: 30,
                     startAt: earlier, createdAt: now, updatedAt: now, someday: true),
            TaskItem(id: "paused-work", categoryId: "work", title: "Paused work", durationMinutes: 30,
                     startAt: earlier, createdAt: now, updatedAt: now, someday: true),
            TaskItem(id: "completed", categoryId: "work", title: "Completed", durationMinutes: 30,
                     dueAt: earlier, completedAt: now, createdAt: now, updatedAt: now),
            TaskItem(id: "deleted", categoryId: "work", title: "Deleted", durationMinutes: 30,
                     dueAt: earlier, createdAt: now, updatedAt: now, deletedAt: now),
        ]
        for task in tasks { try database.saveTask(task, now: now) }
        let limited = try #require(WidgetStore.openTasks(limit: 1, at: now, from: database))
        #expect(limited.count == 3)
        #expect(limited.tasks.map(\.id) == ["due"])
        let all = try #require(WidgetStore.openTasks(limit: 10, at: now, from: database))
        #expect(all.count == 3)
        #expect(all.tasks.map(\.id) == ["due", "start", "pin"])
        #expect(all.tasks.map(\.listDate) == [.due(earlier), .start(now), .pinned(now.addingTimeInterval(60))])
    }

    @Test func somedayIsExcludedBeforeTimelineBoundariesAndProjection() {
        let now = JSONCoding.parseInstant("2026-11-12T20:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let ordinary = TaskItem(id: "ordinary", categoryId: "work", title: "Ordinary", durationMinutes: 30,
                                deadlineType: .soft, dueAt: now.addingTimeInterval(300), createdAt: now, updatedAt: now)
        var deferred = ordinary
        deferred.id = "deferred"
        deferred.someday = true
        deferred.dueAt = now.addingTimeInterval(60)
        let snapshot = WidgetTaskTimeline(tasks: [deferred, ordinary], categories: [], placements: [:], calendar: calendar)
        #expect(snapshot.tasks.map(\.id) == [ordinary.id])
        #expect(snapshot.rows(limit: 1, at: now).map(\.id) == [ordinary.id])
        #expect(snapshot.dates(at: now) == [now, ordinary.dueAt!, calendar.startOfDay(for: now.addingTimeInterval(86_400))])
        let row = WidgetTask(task: deferred, placements: [], category: nil, at: now.addingTimeInterval(120))
        #expect(!row.late && row.listDate == nil)
    }

    @Test func displayedFallbackDatesNameTheirKind() {
        let now = JSONCoding.parseInstant("2026-11-12T20:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(WidgetFormatting.taskDateLabel(.due(now), now: now, calendar: calendar) == "Today")
        #expect(WidgetFormatting.taskDateLabel(.start(now), now: now, calendar: calendar) == "Start Today")
        #expect(WidgetFormatting.taskDateLabel(.pinned(now), now: now, calendar: calendar) == "Pinned Today")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        #expect(WidgetFormatting.taskDateLabel(.start(tomorrow), now: now, calendar: calendar) == "Start Tomorrow")
        #expect(WidgetFormatting.taskDateLabel(.pinned(tomorrow), now: now, calendar: calendar) == "Pinned Tomorrow")
    }
}
