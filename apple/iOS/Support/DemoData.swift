#if DEBUG
import FloridaKit
import Foundation

/// Sample data for screenshot runs (`-demoData YES`): two Google accounts with four calendars,
/// four categories, a day of meetings around scheduled task blocks, and more blocks tomorrow. All
/// times are relative to `now`, so the Agenda tab's "today" is always populated.
enum DemoData {
    static func syncResponse(now: Date, calendar: Calendar) -> SyncResponse {
        let today = calendar.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func task(
            _ id: String, _ categoryId: String, _ title: String, minutes: Int, priority: Priority,
            due: Date? = nil, hard: Bool = false, notes: String? = nil
        ) -> TaskItem {
            TaskItem(
                id: id, categoryId: categoryId, title: title, notes: notes, durationMinutes: minutes,
                priority: priority, deadlineType: due == nil ? .none : (hard ? .hard : .soft), dueAt: due,
                createdAt: now, updatedAt: now)
        }
        func block(_ id: String, _ taskId: String, _ start: Date, _ end: Date) -> Placement {
            Placement(id: id, taskId: taskId, startAt: start, endAt: end, pinned: false, computedAt: now)
        }
        func event(
            _ id: String, _ calendarId: String, _ summary: String, _ start: Date, _ end: Date,
            allDay: Bool = false, location: String? = nil
        ) -> CalendarEvent {
            CalendarEvent(
                id: id, calendarId: calendarId, googleId: "g-\(id)", summary: summary, location: location,
                startAt: start, endAt: end, allDay: allDay, responseStatus: "accepted", updatedAt: now)
        }

        let zone = calendar.timeZone.identifier
        let workHours = "demo-work-hours"
        let evenings = "demo-evenings"
        let inbox = "demo-inbox", engineering = "demo-eng", infosec = "demo-infosec", finance = "demo-finance"
        let work = "demo-cal-work", ooo = "demo-cal-ooo", personal = "demo-cal-personal", birthdays = "demo-cal-birthdays"

        return SyncResponse(
            cursor: now.ISO8601Format(),
            schedules: [
                Schedule(
                    id: workHours, name: "Work hours", timeZone: zone,
                    windows: [ScheduleWindow(days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00")],
                    createdAt: now, updatedAt: now),
                Schedule(
                    id: evenings, name: "Evenings and weekends", timeZone: zone,
                    windows: [
                        ScheduleWindow(days: [1, 2, 3, 4, 5], start: "18:00", end: "21:00"),
                        ScheduleWindow(days: [0, 6], start: "10:00", end: "18:00"),
                    ],
                    createdAt: now, updatedAt: now),
            ],
            categories: [
                Category(id: inbox, name: "Inbox", scheduleId: workHours, sortOrder: 0, createdAt: now, updatedAt: now),
                Category(id: engineering, name: "Work Engineering", color: "#4F46E5", scheduleId: workHours, sortOrder: 1, createdAt: now, updatedAt: now),
                Category(id: infosec, name: "Work Infosec", color: "#DC2626", scheduleId: workHours, sortOrder: 2, createdAt: now, updatedAt: now),
                Category(id: finance, name: "Personal Finance", color: "#059669", scheduleId: evenings, sortOrder: 3, createdAt: now, updatedAt: now),
            ],
            tasks: [
                task("demo-task-keys", infosec, "Rotate AWS access keys", minutes: 45, priority: .asap, due: at(1, 12), hard: true),
                task("demo-task-pr", engineering, "Review auth service PR", minutes: 60, priority: .high, due: at(0, 17)),
                task("demo-task-flaky", engineering, "Fix flaky scheduler test", minutes: 60, priority: .medium, due: at(0, 12)),
                task("demo-task-roadmap", engineering, "Write Q4 infra roadmap", minutes: 120, priority: .medium, due: at(3, 17),
                     notes: "Cover the Postgres upgrade, the queue migration, and on-call load."),
                task("demo-task-soc2", infosec, "Collect SOC 2 access-review evidence", minutes: 90, priority: .medium, due: at(5, 17)),
                task("demo-task-taxes", finance, "Pay Q4 estimated taxes", minutes: 30, priority: .high, due: at(2, 17), hard: true),
                task("demo-task-funds", finance, "Rebalance index funds", minutes: 45, priority: .low),
                task("demo-task-dentist", inbox, "Book dentist appointment", minutes: 15, priority: .medium),
            ],
            events: [
                event("demo-event-standup", work, "Standup", at(0, 9), at(0, 9, 30)),
                event("demo-event-design", work, "Design review: scheduler v2", at(0, 11, 30), at(0, 12, 30), location: "Zoom"),
                event("demo-event-lunch", personal, "Lunch with Priya", at(0, 12, 30), at(0, 13, 30), location: "Souvla"),
                event("demo-event-1on1", work, "1:1 with Sam", at(0, 14, 30), at(0, 15)),
                event("demo-event-ooo", ooo, "Marcus out of office", at(0, 0), at(1, 0), allDay: true),
                event("demo-event-birthday", birthdays, "Mom's birthday", at(0, 0), at(1, 0), allDay: true),
                event("demo-event-arch", work, "Architecture sync", at(1, 13), at(1, 14)),
            ],
            placements: [
                block("demo-block-keys", "demo-task-keys", at(0, 9, 30), at(0, 10, 15)),
                block("demo-block-pr", "demo-task-pr", at(0, 10, 15), at(0, 11, 15)),
                block("demo-block-flaky", "demo-task-flaky", at(0, 13, 30), at(0, 14, 30)),
                block("demo-block-roadmap-1", "demo-task-roadmap", at(0, 15), at(0, 16)),
                block("demo-block-taxes", "demo-task-taxes", at(0, 18), at(0, 18, 30)),
                block("demo-block-roadmap-2", "demo-task-roadmap", at(1, 9), at(1, 10)),
                block("demo-block-soc2", "demo-task-soc2", at(1, 10), at(1, 11, 30)),
                block("demo-block-dentist", "demo-task-dentist", at(1, 11, 30), at(1, 11, 45)),
                block("demo-block-funds", "demo-task-funds", at(1, 18), at(1, 18, 45)),
            ],
            accounts: [
                GoogleAccount(id: "demo-work", email: "swaraj@work.example", label: "work", updatedAt: now),
                GoogleAccount(id: "demo-personal", email: "swaraj@personal.example", label: "personal", updatedAt: now),
            ],
            calendars: [
                CalendarInfo(id: work, accountId: "demo-work", googleId: "g-work", summary: "Work", color: "#3B82F6", accessRole: "owner", selected: true, updatedAt: now),
                CalendarInfo(id: ooo, accountId: "demo-work", googleId: "g-ooo", summary: "Team OOO", color: "#F59E0B", accessRole: "reader", selected: true, updatedAt: now),
                CalendarInfo(id: personal, accountId: "demo-personal", googleId: "g-personal", summary: "Personal", color: "#10B981", accessRole: "owner", selected: true, updatedAt: now),
                CalendarInfo(id: birthdays, accountId: "demo-personal", googleId: "g-birthdays", summary: "Birthdays", color: "#EC4899", accessRole: "reader", selected: false, updatedAt: now),
            ])
    }
}
#endif
