#if DEBUG
import FloridaKit
import Foundation

/// Sample data for screenshot runs (`-demoData YES`): two Google accounts with four calendars,
/// five categories (Home empty, Inbox with tasks to triage), a day of meetings (with meeting links, guests and a three-day offsite) around
/// scheduled task blocks, more blocks tomorrow, and an optional evening block with suggestions for
/// tonight and tomorrow night. All times are relative to `now`, so the Agenda tab's "today" is
/// always populated.
enum DemoData {
    static let fixedNow: Date? = {
        guard UserDefaults.standard.bool(forKey: "demoData"),
              let value = UserDefaults.standard.string(forKey: "demoNow") else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }()

    static func syncResponse(now: Date, calendar: Calendar) -> SyncResponse {
        if UserDefaults.standard.bool(forKey: "demoUnsynced") {
            return SyncResponse(cursor: now.ISO8601Format())
        }
        let today = calendar.startOfDay(for: now)
        let evening = "demo-routine-evening"
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func task(
            _ id: String, _ categoryId: String, _ title: String, minutes: Int, priority: Priority,
            due: Date? = nil, hard: Bool = false, notes: String? = nil, project: String? = nil
        ) -> TaskItem {
            TaskItem(
                id: id, categoryId: categoryId, title: title, notes: notes, durationMinutes: minutes,
                priority: priority, deadlineType: due == nil ? .none : (hard ? .hard : .soft), dueAt: due,
                createdAt: now, updatedAt: now, projectId: project)
        }
        func block(_ id: String, _ taskId: String, _ start: Date, _ end: Date, lane: Int? = nil) -> Placement {
            Placement(id: id, taskId: taskId, startAt: start, endAt: end, pinned: false, lane: lane, computedAt: now)
        }
        func project(
            _ id: String, _ name: String, _ status: ProjectStatus, _ categoryId: String, order: Int,
            next: String? = nil, parallel: Bool = false, weekly: Int? = nil, notes: String? = nil
        ) -> Project {
            Project(
                id: id, name: name, status: status, categoryId: categoryId, notes: notes, nextStep: next,
                parallel: parallel, weeklyMinutes: weekly, sortOrder: order, createdAt: now, updatedAt: now)
        }
        func dayKey(_ dayOffset: Int) -> String {
            DayOverride.key(for: at(dayOffset, 12), calendar: calendar)
        }
        func suggestion(_ id: String, _ taskId: String, _ start: Date, _ end: Date) -> OptionalPlacement {
            OptionalPlacement(id: id, taskId: taskId, blockId: evening, startAt: start, endAt: end, computedAt: now)
        }
        func event(
            _ id: String, _ calendarId: String, _ summary: String, _ start: Date, _ end: Date,
            allDay: Bool = false, location: String? = nil, meet: String? = nil, series: String? = nil,
            eventType: String? = nil, autoBlocksDay: Bool? = nil, blockingReason: String? = nil
        ) -> CalendarEvent {
            var event = CalendarEvent(
                id: id, calendarId: calendarId, googleId: "g-\(id)", summary: summary, location: location,
                startAt: start, endAt: end, allDay: allDay, responseStatus: "accepted",
                htmlLink: "https://calendar.google.com/calendar/event?eid=\(id)", eventType: eventType, updatedAt: now,
                autoBlocksDay: autoBlocksDay, blockingReason: blockingReason)
            event.conferenceUrl = meet
            event.recurringEventId = series
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
        let gym = "demo-routine-gym"
        let authProject = "demo-project-auth", soc2Project = "demo-project-soc2", vendorProject = "demo-project-vendor"
        let floridaProject = "demo-project-florida"
        let sinceSunday = calendar.component(.weekday, from: today) - 1
        let work = "demo-cal-work", ooo = "demo-cal-ooo", personal = "demo-cal-personal", birthdays = "demo-cal-birthdays"

        var response = SyncResponse(
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
                // A commitment (it allows nothing): afternoons, plus one office-day morning a week.
                RoutineBlock(
                    id: gym, name: "Gym", days: [1, 4, 5], start: "15:30", end: "16:45", allows: [],
                    alternates: [
                        RoutineSlot(day: 2, start: "09:00", end: "10:15"), RoutineSlot(day: 3, start: "09:00", end: "10:15"),
                    ],
                    createdAt: now, updatedAt: now),
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
                task("demo-task-pr", engineering, "Review auth service PR", minutes: 60, priority: .high, due: at(0, 17), project: authProject),
                task("demo-task-flaky", engineering, "Fix flaky scheduler test", minutes: 60, priority: .medium, due: at(0, 12), project: authProject),
                task("demo-task-roadmap", engineering, "Write Q4 infra roadmap", minutes: 120, priority: .medium, due: at(3, 17),
                     notes: "Cover the Postgres upgrade, the queue migration, and on-call load."),
                task("demo-task-soc2", infosec, "Collect SOC 2 access-review evidence", minutes: 90, priority: .medium, due: at(5, 17), project: soc2Project),
                task("demo-task-taxes", finance, "Pay Q4 estimated taxes", minutes: 30, priority: .high, due: at(2, 17), hard: true),
                task("demo-task-funds", finance, "Rebalance index funds", minutes: 45, priority: .low),
                task("demo-task-dentist", inbox, "Book dentist appointment", minutes: 15, priority: .medium),
                task("demo-task-postmortem", engineering, "Draft incident postmortem", minutes: 45, priority: .high, due: at(1, 17)),
                task("demo-task-vpn", inbox, "Renew VPN certificate", minutes: 30, priority: .high, due: at(-1, 17)),
                task("demo-task-offsite", inbox, "Prepare offsite slides", minutes: 240, priority: .medium, due: at(1, 9), hard: true),
            ],
            events: [
                event("demo-event-standup", work, "Standup", at(0, 9), at(0, 9, 30), meet: "https://meet.google.com/stu-ndup-xyz",
                      series: "demo-series-standup"),
                DemoData.designReview(event("demo-event-design", work, "Design review: scheduler v2", at(0, 11, 30), at(0, 12, 30),
                                            location: "Room 4 / Meet", meet: "https://meet.google.com/abc-defg-hij")),
                event("demo-event-lunch", personal, "Lunch with Priya", at(0, 12, 30), at(0, 13, 30), location: "Souvla"),
                event("demo-event-1on1", work, "1:1 with Sam", at(0, 14, 30), at(0, 15)),
                event("demo-event-ooo", ooo, "Marcus out of office", utcDay(0), utcDay(1), allDay: true, eventType: "outOfOffice",
                      autoBlocksDay: false, blockingReason: "A teammate is out of office, not you."),
                DemoData.designReview(event("demo-event-offsite", work, "Infra offsite", utcDay(-1), utcDay(2), allDay: true,
                                            location: "Half Moon Bay", meet: "https://meet.google.com/abc-defg-hij")),
                event("demo-event-birthday", birthdays, "Mom's birthday", utcDay(0), utcDay(1), allDay: true,
                      autoBlocksDay: false, blockingReason: "Birthdays are informational."),
                event("demo-event-holiday", "demo-cal-us-holidays", "Public holiday", utcDay(0), utcDay(1), allDay: true,
                      location: "https://example.com/holiday-details",
                      autoBlocksDay: true, blockingReason: "US public holiday on your calendar."),
                event("demo-event-arch", work, "Architecture sync", at(1, 13), at(1, 14)),
            ],
            placements: [
                // Always in progress, whatever time the screenshot runs, to show the progress fill.
                block("demo-block-postmortem", "demo-task-postmortem", now.addingTimeInterval(-20 * 60), now.addingTimeInterval(25 * 60)),
                block("demo-block-keys", "demo-task-keys", at(0, 9, 30), at(0, 10, 15)),
                block("demo-block-pr", "demo-task-pr", at(0, 10, 15), at(0, 11, 15)),
                // One hour, three parallel projects: two tasks and the vendor review's own time.
                block("demo-block-flaky", "demo-task-flaky", at(0, 13, 30), at(0, 14, 30), lane: 0),
                block("demo-block-soc2-1", "demo-task-soc2", at(0, 13, 30), at(0, 14, 30), lane: 1),
                block("demo-block-roadmap-1", "demo-task-roadmap", at(0, 15), at(0, 15, 30)),
                block("demo-block-roadmap-2", "demo-task-roadmap", at(1, 9), at(1, 10)),
                block("demo-block-soc2", "demo-task-soc2", at(1, 10), at(1, 10, 30)),
                block("demo-block-dentist", "demo-task-dentist", at(1, 11, 30), at(1, 11, 45)),
                block("demo-block-taxes", "demo-task-taxes", at(1, 14), at(1, 14, 30)),
                block("demo-block-funds", "demo-task-funds", at(3, 9), at(3, 9, 45)),
            ],
            // Personal work first, as the scheduler orders an evening; each task keeps its block above.
            optionalPlacements: [
                suggestion("demo-pick-taxes", "demo-task-taxes", at(0, 20), at(0, 20, 30)),
                suggestion("demo-pick-funds", "demo-task-funds", at(0, 20, 30), at(0, 21, 15)),
                suggestion("demo-pick-roadmap", "demo-task-roadmap", at(0, 21, 15), at(0, 22, 15)),
                suggestion("demo-pick-funds-2", "demo-task-funds", at(1, 20), at(1, 20, 45)),
            ],
            accounts: [
                GoogleAccount(id: "demo-work", email: "demo@sempre-health.com", label: "work", updatedAt: now),
                GoogleAccount(id: "demo-personal", email: "demo@personal.example", label: "personal", updatedAt: now, displayName: "Demo Person"),
            ],
            calendars: [
                CalendarInfo(id: "demo-cal-us-holidays", accountId: "demo-personal", googleId: "en.usa#holiday@group.v.calendar.google.com",
                    summary: "US Holidays", accessRole: "reader", selected: false, blocksScheduling: true, updatedAt: now),
                CalendarInfo(id: work, accountId: "demo-work", googleId: "demo@sempre-health.com", summary: "demo@sempre-health.com", color: "#3B82F6", accessRole: "owner", selected: true, updatedAt: now),
                CalendarInfo(id: ooo, accountId: "demo-work", googleId: "g-ooo", summary: "Team OOO", color: "#F59E0B", accessRole: "reader", selected: true, updatedAt: now),
                CalendarInfo(id: personal, accountId: "demo-personal", googleId: "demo@personal.example", summary: "demo@personal.example", color: "#10B981", accessRole: "owner", selected: true, updatedAt: now),
                CalendarInfo(id: birthdays, accountId: "demo-personal", googleId: "g-birthdays", summary: "Birthdays", color: "#EC4899", accessRole: "reader", selected: false, updatedAt: now),
                CalendarInfo(id: "demo-family", accountId: "demo-personal", googleId: "g-family", summary: "A&S Family Calendar", accessRole: "writer", selected: true, updatedAt: now),
                CalendarInfo(id: "demo-colleague", accountId: "demo-work", googleId: "teammate@sempre-health.com", summary: "teammate@sempre-health.com", accessRole: "writer", selected: true, updatedAt: now),
            ],
            unscheduled: [
                UnscheduledTask(taskId: "demo-task-vpn", reason: "no_fit_in_horizon", unplacedMinutes: 30, computedAt: now),
                UnscheduledTask(taskId: "demo-task-offsite", reason: "no_fit_before_hard_deadline", unplacedMinutes: 240, computedAt: now),
            ],
            projects: [
                project(authProject, "Auth service migration", .active, engineering, order: 0,
                        next: "Cut staging over to the new token service", parallel: true,
                        notes: "Claude drives most of this; I review and unblock."),
                project(soc2Project, "SOC 2 renewal", .active, infosec, order: 1,
                        next: "Send the auditor the access-review evidence", parallel: true),
                project(vendorProject, "Vendor risk review", .active, infosec, order: 2,
                        next: "Score the three new vendors", parallel: true, weekly: 120),
                project(floridaProject, "Florida", .active, "demo-home", order: 3,
                        next: "Projects and parallel lanes", weekly: 120),
                project("demo-project-network", "Home network rebuild", .thinking, "demo-home", order: 4,
                        next: "Price out a rack and a UniFi gateway"),
                project("demo-project-oncall", "On-call handbook", .onHold, engineering, order: 5,
                        next: "Waiting on the new paging vendor"),
                project("demo-project-okta", "Okta rollout", .done, infosec, order: 6),
            ],
            // The day after tomorrow is off, whatever weekday it falls on.
            dayOverrides: [DayOverride(date: dayKey(2), kind: .off, note: "School holiday", createdAt: now, updatedAt: now)],
            projectPlacements: [
                ProjectPlacement(
                    id: "demo-time-vendor", projectId: vendorProject, weekOf: dayKey(-sinceSunday),
                    startAt: at(0, 13, 30), endAt: at(0, 14, 30), lane: 2, computedAt: now),
                ProjectPlacement(
                    id: "demo-time-florida", projectId: floridaProject, weekOf: dayKey(-sinceSunday),
                    startAt: at(1, 15), endAt: at(1, 16), computedAt: now),
            ],
            routineOccurrences: [
                RoutineOccurrence(id: "demo-gym-today", blockId: gym, startAt: at(0, 15, 30), endAt: at(0, 16, 45), computedAt: now),
                RoutineOccurrence(id: "demo-gym-later", blockId: gym, startAt: at(3, 15, 30), endAt: at(3, 16, 45), computedAt: now),
            ],
            // The office-morning session found no free slot this week.
            missed: [MissedCommitment(blockId: gym, weekOf: dayKey(-sinceSunday))],
            capacity: [
                DayCapacity(date: dayKey(0), freeMinutes: .init(computer: 45, errand: 45, home: 45)),
                DayCapacity(date: dayKey(1), freeMinutes: .init(computer: 150, errand: 150, home: 150)),
                DayCapacity(date: dayKey(2), freeMinutes: .init()),
                DayCapacity(date: dayKey(3), freeMinutes: .init(computer: 300, errand: 300, home: 300)),
            ],
            briefs: [
                Brief(
                    id: "demo-brief-daily", kind: .daily, date: dayKey(0),
                    headline: "Keys first, then a three-project hour after lunch",
                    body: """
                        Rotate the AWS keys right after standup: they are due tomorrow at noon and nothing else today is hard.
                        From 1:30 run the flaky test fix, the SOC 2 evidence and the vendor review side by side; each is mostly waiting on Claude.
                        Gym at 3:30. Offsite slides do not fit before tomorrow morning, so cut them down or move the deadline.
                        """,
                    createdAt: now, updatedAt: now),
                Brief(
                    id: "demo-brief-weekly", kind: .weekly, date: dayKey(-sinceSunday),
                    headline: "A short week: one day off, taxes due",
                    body: """
                        Estimated taxes are the one hard deadline; they sit in tomorrow's plan and in tonight's suggestions.
                        Auth migration and SOC 2 share most afternoons. Florida gets its two hours tomorrow at 3.
                        No office-morning gym this week: both mornings are taken by the offsite.
                        """,
                    createdAt: now, updatedAt: now),
            ])
        if UserDefaults.standard.bool(forKey: "uiTaskGroupingDemo") {
            response = taskGroupingResponse(response, now: fixedNow ?? now)
        }
        if UserDefaults.standard.bool(forKey: "uiTaskDateDemo") {
            let parse = ISO8601DateFormatter()
            let past = UserDefaults.standard.bool(forKey: "uiTaskDatePast")
            let late = UserDefaults.standard.bool(forKey: "uiTaskDateLate")
            response.tasks = [TaskItem(
                id: "date-updated", categoryId: "demo-finance", title: "Updated account task",
                durationMinutes: 30, priority: .medium, deadlineType: .soft,
                dueAt: parse.date(from: past ? "2026-11-12T07:59:59Z"
                                  : late ? "2026-11-17T19:00:00Z" : "2026-11-18T07:59:59Z"),
                startAt: parse.date(from: "2026-11-17T08:00:00Z"), createdAt: now, updatedAt: now)]
            response.settings = UserSettings(id: "default", timeZone: "America/Los_Angeles", updatedAt: now)
            response.placements = [Placement(
                id: "date-placement", taskId: "date-updated",
                startAt: parse.date(from: "2026-11-17T20:00:00Z")!,
                endAt: parse.date(from: "2026-11-17T20:30:00Z")!, pinned: false, computedAt: now)]
            if UserDefaults.standard.bool(forKey: "uiTaskDateNoPlacement") { response.placements = [] }
            if UserDefaults.standard.bool(forKey: "uiTaskDateSelectionDemo") {
                var other = response.tasks[0]
                other.id = "date-other"
                other.title = "Other account task"
                other.dueAt = parse.date(from: "2026-11-21T07:59:59Z")
                response.tasks.append(other)
            }
            response.optionalPlacements = []
            response.unscheduled = []
        }
        if UserDefaults.standard.bool(forKey: "uiInteractionTripDemo") {
            response.events.append(CalendarEvent(
                id: "interaction-trip", calendarId: "demo-cal-work", googleId: "interaction-trip",
                summary: "Interaction trip", startAt: utcDay(-2), endAt: utcDay(1), allDay: true,
                htmlLink: "https://example.com/interaction-trip", updatedAt: now,
                autoBlocksDay: true, blockingReason: "Your trip"))
        }
        if UserDefaults.standard.bool(forKey: "uiInteractionManyResources"),
           let index = response.events.firstIndex(where: { $0.id == "demo-event-design" }) {
            response.events[index].description = (1...100).map {
                "<a href=\"https://example.com/interaction-resource/\($0)\">Resource \($0)</a>"
            }.joined(separator: "<br>")
        }
        if UserDefaults.standard.bool(forKey: "uiOverlappingStaysDemo") {
            response.events = [
                event("demo-stay-marshall", personal, "Stay at Marshall", utcDay(-2), utcDay(2), allDay: true,
                      autoBlocksDay: true, blockingReason: "Your trip"),
                event("demo-stay-tomales", personal, "Stay at Tomales Bay Retreat", utcDay(-1), utcDay(2), allDay: true,
                      autoBlocksDay: true, blockingReason: "Your trip"),
                event("demo-hidden-sunday", "demo-cal-us-holidays", "Hidden Sunday holiday", utcDay(1), utcDay(2), allDay: true,
                      autoBlocksDay: true, blockingReason: "US public holiday on your calendar."),
            ]
            response.placements = []
            response.optionalPlacements = []
            response.planBlocks = []
            response.briefs = []
            response.unscheduled = []
        }
        return response
    }

    private static func taskGroupingResponse(_ original: SyncResponse, now: Date) -> SyncResponse {
        var response = original
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let today = calendar.startOfDay(for: now)
        func at(_ day: Int, _ hour: Int) -> Date {
            let date = calendar.date(byAdding: .day, value: day, to: today)!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
        }
        func task(_ id: String, _ title: String, category: String, due: Date? = nil,
                  hard: Bool = false, priority: Priority = .medium) -> TaskItem {
            TaskItem(
                id: id, categoryId: category, title: title, durationMinutes: 30, priority: priority,
                deadlineType: due == nil ? .none : (hard ? .hard : .soft), dueAt: due,
                createdAt: now.addingTimeInterval(-86_400), updatedAt: now)
        }
        let engineering = "demo-eng", infosec = "demo-infosec", finance = "demo-finance"
        var todaySoft = task("group-today-soft", "Group today soft", category: engineering, due: at(0, 14), priority: .asap)
        todaySoft.source = TaskSource(url: "https://example.com/grouping", title: "Grouping reference", kind: .web)
        var noDue = task("group-no-due", "Group no due task", category: engineering)
        noDue.startAt = at(30, 9)
        var pinned = task("group-pinned", "Group pinned task", category: infosec)
        pinned.pinnedStart = at(1, 10)
        var someday = task("group-someday", "Group someday task", category: engineering)
        someday.someday = true
        var categorizedInbox = task("group-categorized-inbox", "Group categorized inbox task", category: engineering)
        categorizedInbox.source = TaskSource(url: "https://example.com/inbox", title: "Inbox reference", kind: .web)
        var completed = task("group-completed", "Group completed task", category: engineering, due: at(0, 14))
        completed.completedAt = now.addingTimeInterval(-60)
        completed.completedMinutes = completed.durationMinutes
        response.tasks = [
            task("group-inbox", "Group inbox task", category: TaskCategory.inboxId),
            categorizedInbox,
            task("group-overdue", "Group overdue task", category: finance, due: at(-1, 9), priority: .low),
            task("group-today-early", "Group today early", category: finance, due: at(0, 13), priority: .low),
            task("group-today-hard", "Group today hard", category: infosec, due: at(0, 14), hard: true),
            todaySoft,
            task("group-tomorrow", "Group tomorrow task", category: engineering, due: at(1, 13)),
            task("group-this-week", "Group this week task", category: engineering, due: at(2, 13)),
            task("group-next-week", "Group next week task", category: finance, due: at(7, 13)),
            task("group-later", "Group later task", category: infosec, due: at(21, 13)),
            noDue, pinned, someday, completed,
        ]
        response.settings = UserSettings(id: "default", timeZone: "UTC", updatedAt: now)
        response.placements = []
        response.optionalPlacements = []
        response.unscheduled = []
        return response
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
            Walk through the <b>scheduler v2</b> design.<br><br>\
            <a href="https://docs.google.com/document/d/demo-scheduler/edit">Scheduler v2 RFC</a><br>\
            <a href="https://docs.google.com/spreadsheets/d/demo-capacity/edit">Capacity model</a><br>\
            <a href="https://docs.google.com/presentation/d/demo-review/edit">Review slides</a><br>\
            <a href="https://www.notion.so/demo/decisions">Decision log</a><br>\
            <a href="https://www.figma.com/design/demo/calendar">Calendar mockups</a><br>\
            <a href="https://github.com/example/florida/pull/42">Scheduler implementation</a><br>\
            <a href="https://linear.app/demo/issue/DEMO-21">Scheduler follow-up</a><br>\
            Notes go in https://notes.example.com/design-review<br>\
            <a href="https://zoom.us/j/123456789">Backup room</a><br>\
            <a href="https://meet.google.com/alt-room-xyz">Breakout room</a><br>\
            <a href="https://wiki.example.com/scheduler">Scheduler runbook</a><br>\
            Doc again: https://docs.google.com/document/d/demo-scheduler/edit<br>\
            Join: https://meet.google.com/abc-defg-hij<ul><li>Chunking rules</li><li>Hard deadlines</li></ul>
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
