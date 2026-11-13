import Foundation
import Testing
@testable import FloridaCore

@Suite struct TaskListGroupingTests {
    static let calendar = calendar(timeZone: "America/Los_Angeles", firstWeekday: 2)
    static let now = date(2026, 11, 12, 12)

    static func calendar(timeZone: String, firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
        calendar: Calendar = Self.calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func task(
        _ id: String, due: Date? = nil, category: String = "work", title: String? = nil,
        deadline: DeadlineType = .soft, priority: Priority = .medium, start: Date? = nil,
        completed: Date? = nil, deleted: Date? = nil
    ) -> TaskItem {
        TaskItem(
            id: id, categoryId: category, title: title ?? id, durationMinutes: 30,
            priority: priority, deadlineType: deadline, dueAt: due, startAt: start,
            completedAt: completed, createdAt: now, updatedAt: now, deletedAt: deleted
        )
    }

    static func category(
        _ id: String, _ name: String, _ area: CategoryArea? = nil, deleted: Date? = nil
    ) -> TaskCategory {
        TaskCategory(
            id: id, name: name, area: area, scheduleId: "routine", createdAt: now,
            updatedAt: now, deletedAt: deleted
        )
    }

    static func sections(
        _ tasks: [TaskItem], grouping: TaskListGrouping = .dueDate,
        categories: [TaskCategory] = [], now: Date = Self.now, calendar: Calendar = Self.calendar
    ) -> [TaskListSection] {
        grouping.sections(tasks: tasks, categories: categories, now: now, calendar: calendar)
    }

    @Test func publicModeNamesAreStable() {
        #expect(TaskListGrouping.allCases.map(\.rawValue) == ["dueDate", "category"])
        #expect(TaskListGrouping.allCases.map(\.title) == ["Due date", "Category"])
    }

    @Test func dueSectionsHaveSemanticOrderAndStableIDs() {
        let tasks = [
            Self.task("none"),
            Self.task("later", due: Self.date(2026, 11, 23)),
            Self.task("next", due: Self.date(2026, 11, 16)),
            Self.task("week", due: Self.date(2026, 11, 15, 23, 59)),
            Self.task("tomorrow", due: Self.date(2026, 11, 13)),
            Self.task("today", due: Self.now),
            Self.task("past", due: Self.date(2026, 11, 11, 23, 59)),
        ]
        let sections = Self.sections(tasks)
        #expect(sections.map(\.id) == ["overdue", "today", "tomorrow", "this-week", "next-week", "later", "no-due-date"])
        #expect(sections.map(\.title) == ["Overdue", "Today", "Tomorrow", "This week", "Next week", "Later", "No due date"])
        #expect(sections.flatMap(\.tasks).map(\.id) == ["past", "today", "tomorrow", "week", "next", "later", "none"])
        #expect(sections.allSatisfy { $0.category == nil && !$0.isInbox })
        #expect(Self.sections([tasks[2]]).map(\.id) == ["next-week"])
        #expect(Self.sections([]).isEmpty)
    }

    @Test func overdueIncludesElapsedTimesTodayButNotTheCurrentInstant() {
        let sections = Self.sections([
            Self.task("earlier", due: Self.date(2026, 11, 12, 11, 59)),
            Self.task("now", due: Self.now),
            Self.task("later", due: Self.date(2026, 11, 12, 12, 1)),
        ])
        #expect(sections.map(\.id) == ["overdue", "today"])
        #expect(sections[0].tasks.map(\.id) == ["earlier"])
        #expect(sections[1].tasks.map(\.id) == ["now", "later"])
    }

    @Test(arguments: ["America/Los_Angeles", "Asia/Tokyo"])
    func dayBoundariesUseTheSuppliedTimeZone(timeZone: String) {
        let calendar = Self.calendar(timeZone: timeZone, firstWeekday: 2)
        let now = Self.date(2026, 11, 12, 23, 30, calendar: calendar)
        let sections = Self.sections([
            Self.task("today", due: Self.date(2026, 11, 12, 23, 59, calendar: calendar)),
            Self.task("tomorrow", due: Self.date(2026, 11, 13, calendar: calendar)),
            Self.task("week", due: Self.date(2026, 11, 14, calendar: calendar)),
        ], now: now, calendar: calendar)
        #expect(sections.map(\.id) == ["today", "tomorrow", "this-week"])
        #expect(sections.flatMap(\.tasks).map(\.id) == ["today", "tomorrow", "week"])
    }

    @Test(arguments: [1, 2])
    func weekBoundariesRespectSundayOrMondayStart(firstWeekday: Int) {
        let calendar = Self.calendar(timeZone: "America/Los_Angeles", firstWeekday: firstWeekday)
        let tasks = [15, 16, 22, 23].map { Self.task("day-\($0)", due: Self.date(2026, 11, $0)) }
        let sections = Self.sections(tasks, now: Self.date(2026, 11, 13, 12), calendar: calendar)
        if firstWeekday == 1 {
            #expect(sections.map(\.id) == ["next-week", "later"])
            #expect(sections[0].tasks.map(\.id) == ["day-15", "day-16"])
            #expect(sections[1].tasks.map(\.id) == ["day-22", "day-23"])
        } else {
            #expect(sections.map(\.id) == ["this-week", "next-week", "later"])
            #expect(sections[0].tasks.map(\.id) == ["day-15"])
            #expect(sections[1].tasks.map(\.id) == ["day-16", "day-22"])
            #expect(sections[2].tasks.map(\.id) == ["day-23"])
        }
    }

    @Test(arguments: [1, 2])
    func todayAndTomorrowWinAcrossAWeekBoundary(firstWeekday: Int) {
        let calendar = Self.calendar(timeZone: "America/Los_Angeles", firstWeekday: firstWeekday)
        let lastDay = firstWeekday == 1 ? 14 : 15
        let sections = Self.sections([
            Self.task("tomorrow", due: Self.date(2026, 11, lastDay + 1)),
            Self.task("next", due: Self.date(2026, 11, lastDay + 2)),
        ], now: Self.date(2026, 11, lastDay, 12), calendar: calendar)
        #expect(sections.map(\.id) == ["tomorrow", "next-week"])
        #expect(sections[0].tasks.map(\.id) == ["tomorrow"])
        #expect(Self.sections([
            Self.task("today", due: Self.date(2026, 11, lastDay + 1, 23)),
        ], now: Self.date(2026, 11, lastDay + 1, 12), calendar: calendar).map(\.id) == ["today"])
    }

    @Test(arguments: [3, 11])
    func dayBoundariesFollowShortAndLongDSTDays(month: Int) {
        let day = month == 3 ? 8 : 1
        let previousDay = Self.calendar.date(byAdding: .day, value: -1, to: Self.date(2026, month, day))!
        let now = Self.calendar.date(bySettingHour: 23, minute: 30, second: 0, of: previousDay)!
        let sections = Self.sections([
            Self.task("tomorrow", due: Self.date(2026, month, day, 23, 45)),
            Self.task("next", due: Self.date(2026, month, day + 1)),
        ], now: now)
        #expect(sections.map(\.id) == ["tomorrow", "next-week"])
        #expect(sections[0].tasks.map(\.id) == ["tomorrow"])
        let nextDay = Self.date(2026, month, day + 1)
        let lateToday = Self.sections([
            Self.task("today", due: Self.date(2026, month, day, 23, 45)),
            Self.task("tomorrow", due: nextDay),
        ], now: Self.date(2026, month, day, 0, 30))
        #expect(lateToday.map(\.id) == ["today", "tomorrow"])
        #expect(nextDay.timeIntervalSince(Self.date(2026, month, day)) == (month == 3 ? 23 : 25) * 3600)
    }

    @Test func dueDateIsUsedRegardlessOfDeadlineTypeOrFutureStart() {
        let future = Self.date(2027, 1, 1)
        let sections = Self.sections([
            Self.task("hard", due: Self.now, deadline: .hard, start: future),
            Self.task("soft", due: Self.now, deadline: .soft, start: future),
            Self.task("unclassified", due: Self.now, deadline: .none, start: future),
            Self.task("no-due", start: future),
        ])
        #expect(sections.map(\.id) == ["today", "no-due-date"])
        #expect(sections[0].tasks.map(\.id) == ["hard", "soft", "unclassified"])
        #expect(sections[1].tasks.map(\.id) == ["no-due"])
    }

    @Test(arguments: TaskListGrouping.allCases)
    func everySectionUsesDueDeadlinePriorityTitleAndIDOrdering(grouping: TaskListGrouping) {
        for categoryID in ["work", TaskCategory.inboxId] {
            let tasks = [
                Self.task("none", due: Self.now, category: categoryID, deadline: .none, priority: .asap),
                Self.task("soft", due: Self.now, category: categoryID, deadline: .soft, priority: .asap),
                Self.task("low", due: Self.now, category: categoryID, deadline: .hard, priority: .low),
                Self.task("medium", due: Self.now, category: categoryID, deadline: .hard, priority: .medium),
                Self.task("z-high", due: Self.now, category: categoryID, title: "Zoo", deadline: .hard, priority: .high),
                Self.task("b-high", due: Self.now, category: categoryID, title: "admin", deadline: .hard, priority: .high),
                Self.task("a-high", due: Self.now, category: categoryID, title: "Admin", deadline: .hard, priority: .high),
                Self.task("asap", due: Self.now, category: categoryID, deadline: .hard, priority: .asap),
                Self.task("early", due: Self.now.addingTimeInterval(-1), category: categoryID, priority: .low),
                Self.task("late", due: Self.now.addingTimeInterval(1), category: categoryID, priority: .asap),
                Self.task("nil-soft", category: categoryID, deadline: .soft, priority: .asap),
                Self.task("nil-hard", category: categoryID, deadline: .hard, priority: .low),
            ]
            let expected = ["early", "asap", "a-high", "b-high", "z-high", "medium", "low", "soft", "none", "late", "nil-hard", "nil-soft"]
            let categories = [Self.category(categoryID, categoryID)]
            #expect(Self.sections(tasks, grouping: grouping, categories: categories).flatMap(\.tasks).map(\.id) == expected)
            #expect(Self.sections(Array(tasks.reversed()), grouping: grouping, categories: categories).flatMap(\.tasks).map(\.id) == expected)
        }
    }

    @Test(arguments: TaskListGrouping.allCases)
    func closedTasksAreExcludedAndFutureStartsRemainVisible(grouping: TaskListGrouping) {
        let tasks = [
            Self.task("completed", completed: Self.now),
            Self.task("deleted", deleted: Self.now),
            Self.task("inbox-completed", category: TaskCategory.inboxId, completed: Self.now),
            Self.task("inbox-deleted", category: TaskCategory.inboxId, deleted: Self.now),
            Self.task("future", start: Self.date(2027, 1, 1)),
            Self.task("inbox-future", category: TaskCategory.inboxId, start: Self.date(2027, 1, 1)),
        ]
        let sections = Self.sections(tasks, grouping: grouping)
        #expect(sections.flatMap(\.tasks).map(\.id) == ["inbox-future", "future"])
        #expect(TaskListGrouping.inboxTasks(in: tasks).map(\.id) == ["inbox-future"])
    }

    @Test func categoryModeKeepsCanonicalOrderEmptyHeadersAndOrphans() {
        let categories = [
            Self.category("other", "Other area"),
            Self.category("personal", "Personal", .personal),
            Self.category("work-z", "Zoo", .work),
            Self.category("inbox", "Inbox"),
            Self.category("work-a", "admin", .work),
            Self.category("deleted", "Deleted", .work, deleted: Self.now),
        ]
        let tasks = [
            Self.task("unknown", due: Self.now, category: "missing"),
            Self.task("deleted-category", due: Self.now.addingTimeInterval(-1), category: "deleted"),
            Self.task("work", category: "work-a"),
        ]
        let sections = Self.sections(tasks, grouping: .category, categories: categories)
        #expect(sections.map(\.id) == ["inbox", "category:work-a", "category:work-z", "category:personal", "category:other", "orphans"])
        #expect(sections.map(\.title) == ["Inbox", "admin", "Zoo", "Personal", "Other area", "Other"])
        #expect(sections[0].isInbox && sections[0].tasks.isEmpty)
        #expect(sections[1].tasks.map(\.id) == ["work"])
        #expect(sections[2...4].allSatisfy { $0.tasks.isEmpty && $0.category != nil })
        #expect(sections.last?.category == nil)
        #expect(sections.last?.tasks.map(\.id) == ["deleted-category", "unknown"])
    }

    @Test(arguments: TaskListGrouping.allCases)
    func inboxAppearsOnceFirstAndOnlyTheSharedPredicateFeedsIt(grouping: TaskListGrouping) {
        let categories = [Self.category("work", "Inbox", .work), Self.category("inbox", "Inbox")]
        let tasks = [
            Self.task("inbox-no-due", category: TaskCategory.inboxId),
            Self.task("inbox-overdue", due: Self.now.addingTimeInterval(-1), category: TaskCategory.inboxId),
            Self.task("categorized-no-due"),
            Self.task("categorized-overdue", due: Self.now.addingTimeInterval(-1)),
            Self.task("orphan-no-due", category: "missing"),
        ]
        let sections = Self.sections(tasks, grouping: grouping, categories: categories)
        #expect(sections.first?.id == "inbox")
        #expect(sections.filter(\.isInbox).count == 1)
        #expect(sections.first?.category == categories[1])
        #expect(sections.first?.tasks == TaskListGrouping.inboxTasks(in: tasks))
        #expect(sections.first?.tasks.map(\.id) == ["inbox-overdue", "inbox-no-due"])
        #expect(Set(sections.dropFirst().flatMap(\.tasks).map(\.id)) == ["categorized-no-due", "categorized-overdue", "orphan-no-due"])
        #expect(sections.flatMap(\.tasks).count == tasks.count)
        let emptyInbox = Self.sections([], grouping: grouping, categories: categories)
        #expect(emptyInbox.first?.isInbox == true)
        #expect(emptyInbox.first?.tasks.isEmpty == true)
        let missingCategory = Self.sections(tasks, grouping: grouping)
        #expect(missingCategory.first?.isInbox == true)
        #expect(missingCategory.first?.title == "Inbox")
        #expect(missingCategory.first?.category == nil)
    }
}
