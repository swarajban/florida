import Foundation
import Testing
@testable import FloridaCore

@Suite struct TaskPushTests {
    @Test(arguments: ["America/Los_Angeles", "Asia/Tokyo", "Europe/London"])
    func pushingPreservesLaterStartsAndAdvancesDueUsingTaskDay(_ zone: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 23, minute: 30))!
        let future = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 15))!
        var task = TaskItem(id: "t", categoryId: "inbox", title: "Task", durationMinutes: 60, createdAt: now, updatedAt: now)
        task.dueAt = TaskDay.due(on: now, calendar: calendar)
        task.deadlineType = .hard
        task.startAt = future
        task.pinnedStart = now
        let pushed = TaskDay.pushedToTomorrow(task, now: now, calendar: calendar)
        #expect(pushed.startAt == future)
        #expect(pushed.dueAt == TaskDay.due(task.dueAt!, notBefore: future, calendar: calendar))
        #expect(pushed.pinnedStart == nil)
        #expect(pushed.deadlineType == .hard)
        #expect(!TaskDay.dueHasTime(pushed.dueAt!, calendar: calendar))
    }

    @Test(arguments: ["2026-03-08T09:30:00Z", "2026-11-01T08:30:00Z"])
    func tomorrowUsesCalendarDaysAcrossDST(_ instant: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = JSONCoding.parseInstant(instant)!
        var task = TaskItem(id: "t", categoryId: "inbox", title: "Task", durationMinutes: 60, createdAt: now, updatedAt: now)
        task.dueAt = calendar.date(bySettingHour: 15, minute: 30, second: 0, of: now)
        let pushed = TaskDay.pushedToTomorrow(task, now: now, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        #expect(pushed.startAt == tomorrow)
        #expect(pushed.dueAt == TaskDay.due(task.dueAt!, notBefore: tomorrow, calendar: calendar))
        #expect(calendar.component(.hour, from: pushed.dueAt!) == 15)
        #expect(calendar.component(.minute, from: pushed.dueAt!) == 30)
    }
}
