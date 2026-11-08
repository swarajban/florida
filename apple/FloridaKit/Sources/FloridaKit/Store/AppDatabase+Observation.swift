import Foundation
import GRDB

// Live queries for the apps' view models. Each returns an `AsyncValueObservation` that yields the
// current rows immediately and again after every commit that touched them; iterate it with
// `for try await` from the main actor and assign the result to observable state.

extension AppDatabase {
    /// Live categories, by `sortOrder` then name; the same rows as `categories()`.
    public func observeCategories() -> AsyncValueObservation<[Category]> {
        observe { db in
            try Category.filter(Column("deletedAt") == nil).order(Column("sortOrder"), Column("name")).fetchAll(db)
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

    /// Every placement, by start. The table only ever holds the scheduler's horizon, so the
    /// task list can derive each task's scheduled time from it without a date filter.
    public func observePlacements() -> AsyncValueObservation<[Placement]> {
        observe { db in
            try Placement.order(Column("startAt")).fetchAll(db)
        }
    }

    /// Visible events overlapping `range`, as `events(in:)` returns them.
    public func observeEvents(in range: Range<Date>) -> AsyncValueObservation<[CalendarEvent]> {
        observe { db in
            try Self.events(db, in: range)
        }
    }

    /// The agenda for the calendar day containing `day`, as `agenda(for:calendar:)` returns it,
    /// re-yielded whenever events, placements or tasks change.
    public func observeAgenda(for day: Date, calendar: Calendar) -> AsyncValueObservation<DayAgenda> {
        let range = Self.dayRange(containing: day, calendar: calendar)
        return observe { db in
            try Self.agenda(db, in: range)
        }
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
