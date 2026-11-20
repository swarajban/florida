import FloridaKit
import Foundation
import Testing

struct CalendarTaskLayoutTests {
    @Test func hiddenTasksDoNotTakeCalendarColumnsOrNavigationSlotsButStillOccupyTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 0)
        func at(_ minutes: Int) -> Date { day.addingTimeInterval(Double(minutes) * 60) }
        let task = TaskItem(id: "task", categoryId: "work", title: "Task", durationMinutes: 60, createdAt: day, updatedAt: day)
        var completed = task
        completed.id = "completed"
        completed.completedAt = at(690)
        let placement = Placement(id: "placement", taskId: task.id, startAt: at(540), endAt: at(600), pinned: true, computedAt: day)
        let event = CalendarEvent(id: "event", calendarId: "work", googleId: "event", startAt: at(570), endAt: at(585), updatedAt: day)
        let commitment = PlanBlock(id: "gym", kind: .commitment(blockId: "gym"), title: "Gym", startAt: at(660), endAt: at(690))
        let project = PlanBlock(id: "project", kind: .project(projectId: "work"), title: "Project", startAt: at(720), endAt: at(750))
        let optional = OptionalPlacement(id: "pick", taskId: task.id, blockId: "evening", startAt: at(780), endAt: at(810), computedAt: day)
        let picks = OptionalPicks.on(day: day, placements: [optional], tasksById: [task.id: task],
                                     blocksById: [:], now: day, calendar: calendar).flatMap(\.picks)
        let schedule = Schedule(id: "work", name: "Work", timeZone: "UTC",
                                windows: [ScheduleWindow(days: [4], start: "09:00", end: "17:00")],
                                createdAt: day, updatedAt: day)
        func layout(showTasks: Bool) -> GridLayout {
            GridLayout.build(
                days: [day], events: [event], placements: [placement], suggestions: picks,
                planBlocks: [commitment, project], showTasksOnCalendar: showTasks,
                tasksById: [task.id: task, completed.id: completed], categoriesById: [:], calendarsById: [:],
                schedules: [schedule], options: .init(freeGaps: true), lineLimit: nil, now: day, calendar: calendar)
        }
        let shown = layout(showTasks: true)
        let hidden = layout(showTasks: false)
        #expect(shown.orderedItems.contains(.task(task.id)))
        #expect(shown.orderedItems.contains(.task(completed.id)))
        #expect(shown.orderedItems.contains(.suggestion(optional.id)))
        #expect(hidden.orderedItems.filter { !$0.isGap } == [.event(event.id), .plan(commitment.id), .plan(project.id)])
        #expect(hidden.blocksByDay[0].first?.columnCount == 1)
        #expect(shown.blocksByDay[0].first(where: \.isEvent)?.columnCount == 2)
        #expect(!shown.gapsByDay[0].isEmpty)
        #expect(hidden.gapsByDay == shown.gapsByDay)
    }
}
