import FloridaKit
import Foundation
import Testing

struct CalendarTaskVisibilityTests {
    @Test func hiddenTaskRowsStillCountAsOccupiedTime() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        func at(_ minutes: Int) -> Date { start.addingTimeInterval(Double(minutes) * 60) }
        let task = TaskItem(id: "task", categoryId: "work", title: "Task", durationMinutes: 30, createdAt: start, updatedAt: start)
        let placement = Placement(id: "placement", taskId: task.id, startAt: at(60), endAt: at(90), pinned: true, computedAt: start)
        let ghost = GhostBlock(id: "ghost", taskId: task.id, title: task.title, categoryId: task.categoryId, start: at(40), end: at(60))
        let event = CalendarEvent(id: "event", calendarId: "work", googleId: "event", startAt: start, endAt: at(30), updatedAt: start)
        let commitment = PlanBlock(id: "gym", kind: .commitment(blockId: "gym"), title: "Gym", startAt: at(120), endAt: at(150))
        let project = PlanBlock(id: "project", kind: .project(projectId: "work"), title: "Project", startAt: at(150), endAt: at(180))
        let items: [AgendaItem] = [.event(event), .ghost(ghost), .block(ScheduledBlock(placement: placement, task: task)),
                                   .plan(commitment), .plan(project)]

        let shown = TimelineRow.rows(for: items, now: nil, showsGaps: true)
        let hidden = TimelineRow.rows(for: items, now: nil, showsGaps: true, showsTasks: false)
        #expect(shown.contains(.item(.ghost(ghost))))
        #expect(hidden == [.item(.event(event)), .gap(FreeGap(start: at(90), end: at(120))),
                           .item(.plan(commitment)), .item(.plan(project))])
    }
}
