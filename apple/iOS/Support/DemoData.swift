#if DEBUG
import FloridaKit
import Foundation

/// Sample data for screenshot runs (`-demoData YES`): two Google accounts with four calendars,
/// five categories (Home empty, Inbox with tasks to triage), a day of meetings (with meeting links, guests and a three-day offsite) around
/// scheduled task blocks, more blocks tomorrow, and an optional evening block with suggestions for
/// tonight and tomorrow night. All times are relative to `now`, so the Agenda tab's "today" is
/// always populated.
enum DemoData {
    static func syncResponse(now: Date, calendar: Calendar) -> SyncResponse {
        let today = calendar.startOfDay(for: now)
        let evening = "demo-routine-evening"
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
        func suggestion(_ id: String, _ taskId: String, _ start: Date, _ end: Date) -> OptionalPlacement {
            OptionalPlacement(id: id, taskId: taskId, blockId: evening, startAt: start, endAt: end, computedAt: now)
        }
        func event(
            _ id: String, _ calendarId: String, _ summary: String, _ start: Date, _ end: Date,
            allDay: Bool = false, location: String? = nil, meet: String? = nil
        ) -> CalendarEvent {
            var event = CalendarEvent(
                id: id, calendarId: calendarId, googleId: "g-\(id)", summary: summary, location: location,
                startAt: start, endAt: end, allDay: allDay, responseStatus: "accepted",
                htmlLink: "https://calendar.google.com/calendar/event?eid=\(id)", updatedAt: now)
            event.conferenceUrl = meet
            return event
        }
        /// All-day events are stored as UTC midnights, as the server does.
        func utcDay(_ dayOffset: Int) -> Date {
            let local = calendar.dateComponents([.year, .month, .day], from: at(dayOffset, 12))
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = .gmt
            return utc.date(from: local) ?? today
        }

        let zone = calendar.timeZone.identifier
        let workHours = "demo-work-hours"
        let evenings = "demo-evenings"
        let inbox = TaskCategory.inboxId, engineering = "demo-eng", infosec = "demo-infosec", finance = "demo-finance"
        let work = "demo-cal-work", ooo = "demo-cal-ooo", personal = "demo-cal-personal", birthdays = "demo-cal-birthdays"

        return SyncResponse(
            cursor: now.ISO8601Format(),
            settings: UserSettings(id: "default", timeZone: zone, updatedAt: now),
            routineBlocks: [
                RoutineBlock(
                    id: "demo-routine-home", name: "Home", days: [1, 4, 5], start: "09:00", end: "15:30",
                    allows: [.computer, .errand, .home], createdAt: now, updatedAt: now),
                RoutineBlock(
                    id: "demo-routine-office", name: "Office", days: [2, 3], start: "09:00", end: "16:20",
                    allows: [.computer, .office], createdAt: now, updatedAt: now),
                // Every day, unlike the real Mon–Thu block, so a capture on any weekday has suggestions.
                RoutineBlock(
                    id: evening, name: "Evening", days: [0, 1, 2, 3, 4, 5, 6], start: "20:00", end: "23:00",
                    allows: [.computer, .home], optional: true, createdAt: now, updatedAt: now),
            ],
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
                TaskCategory(id: inbox, name: "Inbox", scheduleId: workHours, sortOrder: 0, createdAt: now, updatedAt: now),
                TaskCategory(id: engineering, name: "Work Engineering", color: "#4F46E5", area: .work, scheduleId: workHours, sortOrder: 1, createdAt: now, updatedAt: now),
                TaskCategory(id: infosec, name: "Work Infosec", color: "#DC2626", area: .work, scheduleId: workHours, sortOrder: 2, createdAt: now, updatedAt: now),
                TaskCategory(id: finance, name: "Personal Finance", color: "#059669", area: .personal, scheduleId: evenings, sortOrder: 3, createdAt: now, updatedAt: now),
                TaskCategory(id: "demo-home", name: "Home", color: "#CA8A04", area: .personal, scheduleId: evenings, sortOrder: 4, createdAt: now, updatedAt: now),
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
                task("demo-task-postmortem", engineering, "Draft incident postmortem", minutes: 45, priority: .high, due: at(1, 17)),
                task("demo-task-vpn", inbox, "Renew VPN certificate", minutes: 30, priority: .high, due: at(-1, 17)),
                task("demo-task-offsite", inbox, "Prepare offsite slides", minutes: 240, priority: .medium, due: at(1, 9), hard: true),
            ],
            events: [
                event("demo-event-standup", work, "Standup", at(0, 9), at(0, 9, 30), meet: "https://meet.google.com/stu-ndup-xyz"),
                DemoData.designReview(event("demo-event-design", work, "Design review: scheduler v2", at(0, 11, 30), at(0, 12, 30),
                                            location: "Room 4 / Meet", meet: "https://meet.google.com/abc-defg-hij")),
                event("demo-event-lunch", personal, "Lunch with Priya", at(0, 12, 30), at(0, 13, 30), location: "Souvla"),
                event("demo-event-1on1", work, "1:1 with Sam", at(0, 14, 30), at(0, 15)),
                event("demo-event-ooo", ooo, "Marcus out of office", utcDay(0), utcDay(1), allDay: true),
                event("demo-event-offsite", work, "Infra offsite", utcDay(-1), utcDay(2), allDay: true, location: "Half Moon Bay"),
                event("demo-event-birthday", birthdays, "Mom's birthday", utcDay(0), utcDay(1), allDay: true),
                event("demo-event-arch", work, "Architecture sync", at(1, 13), at(1, 14)),
            ],
            placements: [
                // Always in progress, whatever time the screenshot runs, to show the progress fill.
                block("demo-block-postmortem", "demo-task-postmortem", now.addingTimeInterval(-20 * 60), now.addingTimeInterval(25 * 60)),
                block("demo-block-keys", "demo-task-keys", at(0, 9, 30), at(0, 10, 15)),
                block("demo-block-pr", "demo-task-pr", at(0, 10, 15), at(0, 11, 15)),
                block("demo-block-flaky", "demo-task-flaky", at(0, 13, 30), at(0, 14, 30)),
                block("demo-block-roadmap-1", "demo-task-roadmap", at(0, 15), at(0, 16)),
                block("demo-block-roadmap-2", "demo-task-roadmap", at(1, 9), at(1, 10)),
                block("demo-block-soc2", "demo-task-soc2", at(1, 10), at(1, 11, 30)),
                block("demo-block-dentist", "demo-task-dentist", at(1, 11, 30), at(1, 11, 45)),
                block("demo-block-taxes", "demo-task-taxes", at(1, 14), at(1, 14, 30)),
                block("demo-block-funds", "demo-task-funds", at(2, 9), at(2, 9, 45)),
            ],
            // Personal work first, as the scheduler orders an evening; each task keeps its block above.
            optionalPlacements: [
                suggestion("demo-pick-taxes", "demo-task-taxes", at(0, 20), at(0, 20, 30)),
                suggestion("demo-pick-funds", "demo-task-funds", at(0, 20, 30), at(0, 21, 15)),
                suggestion("demo-pick-roadmap", "demo-task-roadmap", at(0, 21, 15), at(0, 22, 15)),
                suggestion("demo-pick-funds-2", "demo-task-funds", at(1, 20), at(1, 20, 45)),
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
            ],
            unscheduled: [
                UnscheduledTask(taskId: "demo-task-vpn", reason: "no_fit_in_horizon", unplacedMinutes: 30, computedAt: now),
                UnscheduledTask(taskId: "demo-task-offsite", reason: "no_fit_before_hard_deadline", unplacedMinutes: 240, computedAt: now),
            ])
    }

    #if os(iOS)
    /// What an AI parse of a pasted email would return, for the `-uiSheet aitask` screenshot.
    @MainActor
    static func parsedTask(model: AppModel) -> TaskEditorRequest {
        var task = model.newTaskTemplate()
        task.title = "Send vendor security questionnaire"
        task.notes = "Pasted from Dana's email: needs SOC 2 report and pen-test summary."
        task.durationMinutes = 60
        task.priority = .high
        task.deadlineType = .hard
        task.dueAt = model.calendar.date(byAdding: .day, value: 3, to: model.today)
            .flatMap { model.calendar.date(bySettingHour: 17, minute: 0, second: 0, of: $0) }
        task.categoryId = "demo-infosec"
        return TaskEditorRequest(
            task: task, isNew: true,
            rationale: "“by Thursday EOD” is a hard deadline; security paperwork fits Work Infosec; about an hour of work.")
    }
    #endif

    /// Guests, an organizer and an HTML description, as Google sends them.
    static func designReview(_ base: CalendarEvent) -> CalendarEvent {
        var event = base
        event.description = """
            Walk through the <b>scheduler v2</b> design.<br><br>Doc: <a href="https://docs.example.com/scheduler-v2">Scheduler v2 RFC</a>\
            <br>Notes go in https://notes.example.com/design-review<ul><li>Chunking rules</li><li>Hard deadlines</li></ul>
            """
        event.organizer = EventOrganizer(email: "priya@work.example", displayName: "Priya Raman", isSelf: false)
        event.attendees = [
            EventAttendee(email: "priya@work.example", displayName: "Priya Raman", responseStatus: "accepted", organizer: true, isSelf: false, optional: false),
            EventAttendee(email: "swaraj@work.example", displayName: "Swaraj", responseStatus: "accepted", organizer: false, isSelf: true, optional: false),
            EventAttendee(email: "sam@work.example", displayName: "Sam Lee", responseStatus: "tentative", organizer: false, isSelf: false, optional: false),
            EventAttendee(email: "marcus@work.example", displayName: nil, responseStatus: "declined", organizer: false, isSelf: false, optional: true),
            EventAttendee(email: "dana@work.example", displayName: "Dana Kim", responseStatus: "needsAction", organizer: false, isSelf: false, optional: false),
        ]
        return event
    }
}
#endif
