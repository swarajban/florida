import Foundation
import GRDB

// Live queries for the apps' view models. Each returns an `AsyncValueObservation` that yields the
// current rows immediately and again after every commit that touched them; iterate it with
// `for try await` from the main actor and assign the result to observable state.

extension AppDatabase {
    /// Live categories, as `categories()` returns them.
    public func observeCategories() -> AsyncValueObservation<[TaskCategory]> {
        observe { db in
            try Self.categories(db)
        }
    }

    /// Live routine blocks, as `routineBlocks()` returns them.
    public func observeRoutineBlocks() -> AsyncValueObservation<[RoutineBlock]> {
        observe { db in
            try Self.routineBlocks(db)
        }
    }

    /// The server's settings row, as `userSettings()` returns it.
    public func observeUserSettings() -> AsyncValueObservation<UserSettings?> {
        observe { db in
            try UserSettings.fetchOne(db)
        }
    }

    /// Live schedules, oldest first.
    public func observeSchedules() -> AsyncValueObservation<[Schedule]> {
        observe { db in
            try Schedule.filter(Column("deletedAt") == nil).order(Column("createdAt"), Column("id")).fetchAll(db)
        }
    }

    /// Tasks that are neither deleted nor completed, in the same order as `openTasks()`.
    public func observeOpenTasks() -> AsyncValueObservation<[TaskItem]> {
        observe { db in
            try TaskItem.fetchAll(db, sql: """
                SELECT * FROM task
                WHERE deletedAt IS NULL AND completedAt IS NULL
                ORDER BY \(Self.priorityRankSQL), dueAt IS NULL, dueAt, createdAt
                """)
        }
    }

    /// Live tasks including completions, for calendar history as well as the open-task pane.
    public func observeTasks() -> AsyncValueObservation<[TaskItem]> {
        observe { db in
            try TaskItem.fetchAll(db, sql: """
                SELECT * FROM task
                WHERE deletedAt IS NULL
                ORDER BY \(Self.priorityRankSQL), dueAt IS NULL, dueAt, createdAt
                """)
        }
    }

    /// Every placement, by start. The table only ever holds the scheduler's horizon, so the
    /// task list can derive each task's scheduled time from it without a date filter.
    public func observePlacements() -> AsyncValueObservation<[Placement]> {
        observe { db in
            try Self.placements(db)
        }
    }

    /// Suggestions for optional routine blocks, as `optionalPlacements()` returns them.
    public func observeOptionalPlacements() -> AsyncValueObservation<[OptionalPlacement]> {
        observe { db in
            try Self.optionalPlacements(db)
        }
    }

    /// Tasks the last scheduler run could not fully place, as `unscheduled()` returns them.
    public func observeUnscheduled() -> AsyncValueObservation<[UnscheduledTask]> {
        observe { db in
            try Self.unscheduled(db)
        }
    }

    /// Visible events overlapping `range`, as `events(in:calendar:)` returns them.
    public func observeEvents(
        in range: Range<Date>, calendar: Calendar = .autoupdatingCurrent
    ) -> AsyncValueObservation<[CalendarEvent]> {
        observe { db in
            try Self.events(db, in: range, calendar: calendar)
        }
    }

    public func observeEvent(id: String) -> AsyncValueObservation<CalendarEvent?> {
        observe { try CalendarEvent.fetchOne($0, key: id) }
    }

    /// The agenda for the calendar day containing `day`, as `agenda(for:calendar:)` returns it,
    /// re-yielded whenever events, placements, tasks, the routine or projects change.
    public func observeAgenda(for day: Date, calendar: Calendar) -> AsyncValueObservation<DayAgenda> {
        let range = Self.dayRange(containing: day, calendar: calendar)
        return observe { db in
            try Self.agenda(db, in: range, calendar: calendar)
        }
    }

    /// Live projects, as `projects()` returns them.
    public func observeProjects() -> AsyncValueObservation<[Project]> {
        observe { db in try Self.projects(db) }
    }

    /// Live day overrides, as `dayOverrides()` returns them.
    public func observeDayOverrides() -> AsyncValueObservation<[DayOverride]> {
        observe { db in try Self.dayOverrides(db) }
    }

    /// Time held for projects, as `projectPlacements()` returns it.
    public func observeProjectPlacements() -> AsyncValueObservation<[ProjectPlacement]> {
        observe { db in try Self.projectPlacements(db) }
    }

    /// The commitments' occurrences, as `routineOccurrences()` returns them.
    public func observeRoutineOccurrences() -> AsyncValueObservation<[RoutineOccurrence]> {
        observe { db in try Self.routineOccurrences(db) }
    }

    /// The plan summary, as `planSummary()` returns it.
    public func observePlanSummary() -> AsyncValueObservation<PlanSummary> {
        observe { db in try PlanSummary.fetchOne(db) ?? PlanSummary() }
    }

    /// The stored briefs, as `briefs()` returns them.
    public func observeBriefs() -> AsyncValueObservation<[Brief]> {
        observe { db in try Self.briefs(db) }
    }

    public func observeAccounts() -> AsyncValueObservation<[GoogleAccount]> {
        observe { db in
            try GoogleAccount.order(Column("email")).fetchAll(db)
        }
    }

    public func observeCalendars() -> AsyncValueObservation<[CalendarInfo]> {
        observe { db in
            try CalendarInfo.order(Column("accountId"), Column("summary")).fetchAll(db)
        }
    }

    /// How many local writes are waiting to be pushed.
    public func observePendingWriteCount() -> AsyncValueObservation<Int> {
        observe { db in
            try PendingWrite.fetchCount(db)
        }
    }
}
