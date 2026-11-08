import Foundation

// Wire-compatible mirrors of the server's rows (server/src/db/schema.ts) and API bodies
// (server/src/app.ts). Field names match the JSON the server sends; dates are ISO 8601 instants
// and are coded with `JSONCoding`.

public enum Priority: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case asap, high, medium, low

    /// Scheduling order: asap first, low last.
    public static func < (lhs: Priority, rhs: Priority) -> Bool {
        lhs.rank < rhs.rank
    }

    public var rank: Int {
        switch self {
        case .asap: 0
        case .high: 1
        case .medium: 2
        case .low: 3
        }
    }
}

public enum DeadlineType: String, Codable, Hashable, Sendable, CaseIterable {
    case hard, soft, none
}

/// A weekly availability window as wall-clock time in the schedule's time zone.
public struct ScheduleWindow: Codable, Hashable, Sendable {
    /// Days of week the window applies to: 0 = Sunday … 6 = Saturday.
    public var days: [Int]
    /// "HH:MM", 24-hour.
    public var start: String
    /// "HH:MM", 24-hour; after `start` on the same day.
    public var end: String

    public init(days: [Int], start: String, end: String) {
        self.days = days
        self.start = start
        self.end = end
    }
}

public struct Schedule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// IANA identifier, e.g. "America/Los_Angeles".
    public var timeZone: String
    public var windows: [ScheduleWindow]
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String, name: String, timeZone: String, windows: [ScheduleWindow],
        createdAt: Date, updatedAt: Date, deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.timeZone = timeZone
        self.windows = windows
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct Category: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// CSS-style hex color such as "#4F46E5", or nil for the default.
    public var color: String?
    public var scheduleId: String
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String, name: String, color: String? = nil, scheduleId: String, sortOrder: Int = 0,
        createdAt: Date, updatedAt: Date, deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.scheduleId = scheduleId
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A to-do. Named `TaskItem` because `Task` is Swift's concurrency type.
public struct TaskItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var categoryId: String
    public var title: String
    public var notes: String?
    public var durationMinutes: Int
    /// Smallest piece the scheduler may split the task into; nil means one contiguous block.
    public var minChunkMinutes: Int?
    public var priority: Priority
    public var deadlineType: DeadlineType
    public var dueAt: Date?
    public var startAt: Date?
    /// Overrides the category's schedule when set.
    public var scheduleId: String?
    /// When set the task is fixed at this instant as one block.
    public var pinnedStart: Date?
    public var completedMinutes: Int
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String, categoryId: String, title: String, notes: String? = nil, durationMinutes: Int,
        minChunkMinutes: Int? = nil, priority: Priority = .medium, deadlineType: DeadlineType = .none,
        dueAt: Date? = nil, startAt: Date? = nil, scheduleId: String? = nil, pinnedStart: Date? = nil,
        completedMinutes: Int = 0, completedAt: Date? = nil, createdAt: Date, updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.categoryId = categoryId
        self.title = title
        self.notes = notes
        self.durationMinutes = durationMinutes
        self.minChunkMinutes = minChunkMinutes
        self.priority = priority
        self.deadlineType = deadlineType
        self.dueAt = dueAt
        self.startAt = startAt
        self.scheduleId = scheduleId
        self.pinnedStart = pinnedStart
        self.completedMinutes = completedMinutes
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isOpen: Bool { deletedAt == nil && completedAt == nil }
    public var remainingMinutes: Int { max(0, durationMinutes - completedMinutes) }
}

/// Scheduler output for one piece of a task. Derived data; the server replaces all rows on every run.
public struct Placement: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var startAt: Date
    public var endAt: Date
    public var pinned: Bool
    public var computedAt: Date

    public init(id: String, taskId: String, startAt: Date, endAt: Date, pinned: Bool, computedAt: Date) {
        self.id = id
        self.taskId = taskId
        self.startAt = startAt
        self.endAt = endAt
        self.pinned = pinned
        self.computedAt = computedAt
    }
}

/// A mirrored Google Calendar event.
public struct CalendarEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var calendarId: String
    public var googleId: String
    /// Google status: "confirmed", "tentative", or "cancelled".
    public var status: String
    public var summary: String?
    public var location: String?
    public var startAt: Date?
    public var endAt: Date?
    public var allDay: Bool
    /// "opaque" (busy, default) or "transparent" (free).
    public var transparency: String?
    /// The user's own attendee response: "accepted", "declined", "tentative", "needsAction".
    public var responseStatus: String?
    public var htmlLink: String?
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String, calendarId: String, googleId: String, status: String = "confirmed", summary: String? = nil,
        location: String? = nil, startAt: Date? = nil, endAt: Date? = nil, allDay: Bool = false,
        transparency: String? = nil, responseStatus: String? = nil, htmlLink: String? = nil,
        updatedAt: Date, deletedAt: Date? = nil
    ) {
        self.id = id
        self.calendarId = calendarId
        self.googleId = googleId
        self.status = status
        self.summary = summary
        self.location = location
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.transparency = transparency
        self.responseStatus = responseStatus
        self.htmlLink = htmlLink
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Whether the event occupies time on the calendar: live, timed, not declined.
    public var isVisible: Bool {
        deletedAt == nil && status != "cancelled" && responseStatus != "declined"
    }
}

/// A connected Google account, without any tokens.
public struct GoogleAccount: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var email: String
    /// Short slug such as "work" or "personal".
    public var label: String
    public var updatedAt: Date

    public init(id: String, email: String, label: String, updatedAt: Date) {
        self.id = id
        self.email = email
        self.label = label
        self.updatedAt = updatedAt
    }
}

/// One Google calendar of a connected account, without sync or channel internals.
public struct CalendarInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var accountId: String
    public var googleId: String
    public var summary: String
    public var color: String?
    public var accessRole: String
    /// Whether events from this calendar are mirrored and block time.
    public var selected: Bool
    public var updatedAt: Date

    public init(
        id: String, accountId: String, googleId: String, summary: String, color: String? = nil,
        accessRole: String, selected: Bool, updatedAt: Date
    ) {
        self.id = id
        self.accountId = accountId
        self.googleId = googleId
        self.summary = summary
        self.color = color
        self.accessRole = accessRole
        self.selected = selected
        self.updatedAt = updatedAt
    }
}

// MARK: - API payloads

/// `GET /api/sync?since=` response. `schedules`, `categories`, `tasks` and `events` contain rows changed
/// after `since`, including tombstones (`deletedAt` set). `placements`, `accounts` and `calendars`
/// are always the complete tables and are meant to be replaced wholesale.
public struct SyncResponse: Codable, Sendable {
    /// Server time when the diff was taken; pass back as the next `since`.
    public var cursor: String
    public var schedules: [Schedule]
    public var categories: [Category]
    public var tasks: [TaskItem]
    public var events: [CalendarEvent]
    public var placements: [Placement]
    public var accounts: [GoogleAccount]
    public var calendars: [CalendarInfo]

    public init(
        cursor: String, schedules: [Schedule] = [], categories: [Category] = [], tasks: [TaskItem] = [],
        events: [CalendarEvent] = [], placements: [Placement] = [], accounts: [GoogleAccount] = [],
        calendars: [CalendarInfo] = []
    ) {
        self.cursor = cursor
        self.schedules = schedules
        self.categories = categories
        self.tasks = tasks
        self.events = events
        self.placements = placements
        self.accounts = accounts
        self.calendars = calendars
    }
}

/// The scheduler's result as returned by every mutating API call (`scheduling`) and `POST /api/schedule/run`.
public struct SchedulingResult: Codable, Hashable, Sendable {
    public struct Piece: Codable, Hashable, Sendable {
        public var taskId: String
        public var start: Date
        public var end: Date
        public var pinned: Bool

        public init(taskId: String, start: Date, end: Date, pinned: Bool) {
            self.taskId = taskId
            self.start = start
            self.end = end
            self.pinned = pinned
        }
    }

    public struct Unscheduled: Codable, Hashable, Sendable {
        public var taskId: String
        /// "no_fit_in_horizon", "no_fit_before_hard_deadline", or "unknown_schedule".
        public var reason: String
        public var unplacedMinutes: Int

        public init(taskId: String, reason: String, unplacedMinutes: Int) {
            self.taskId = taskId
            self.reason = reason
            self.unplacedMinutes = unplacedMinutes
        }
    }

    public struct Late: Codable, Hashable, Sendable {
        public var taskId: String
        public var dueAt: Date
        public var eta: Date

        public init(taskId: String, dueAt: Date, eta: Date) {
            self.taskId = taskId
            self.dueAt = dueAt
            self.eta = eta
        }
    }

    public var placements: [Piece]
    public var unscheduled: [Unscheduled]
    public var late: [Late]

    public init(placements: [Piece] = [], unscheduled: [Unscheduled] = [], late: [Late] = []) {
        self.placements = placements
        self.unscheduled = unscheduled
        self.late = late
    }

    /// Converts the pieces into `Placement` rows, as the server stores them after this run.
    public func placementRows(computedAt: Date, makeId: () -> String = { UUID().uuidString.lowercased() }) -> [Placement] {
        placements.map {
            Placement(id: makeId(), taskId: $0.taskId, startAt: $0.start, endAt: $0.end, pinned: $0.pinned, computedAt: computedAt)
        }
    }
}

/// Body of `PUT /api/tasks/:id`.
public struct TaskWrite: Codable, Hashable, Sendable {
    public var categoryId: String
    public var title: String
    public var notes: String?
    public var durationMinutes: Int
    public var minChunkMinutes: Int?
    public var priority: Priority
    public var deadlineType: DeadlineType
    public var dueAt: Date?
    public var startAt: Date?
    public var scheduleId: String?
    public var pinnedStart: Date?
    public var completedMinutes: Int
    public var completedAt: Date?

    public init(_ task: TaskItem) {
        categoryId = task.categoryId
        title = task.title
        notes = task.notes
        durationMinutes = task.durationMinutes
        minChunkMinutes = task.minChunkMinutes
        priority = task.priority
        deadlineType = task.deadlineType
        dueAt = task.dueAt
        startAt = task.startAt
        scheduleId = task.scheduleId
        pinnedStart = task.pinnedStart
        completedMinutes = task.completedMinutes
        completedAt = task.completedAt
    }
}

/// Body of `PUT /api/categories/:id`.
public struct CategoryWrite: Codable, Hashable, Sendable {
    public var name: String
    public var color: String?
    public var scheduleId: String
    public var sortOrder: Int

    public init(_ category: Category) {
        name = category.name
        color = category.color
        scheduleId = category.scheduleId
        sortOrder = category.sortOrder
    }
}

/// Body of `PUT /api/schedules/:id`.
public struct ScheduleWrite: Codable, Hashable, Sendable {
    public var name: String
    public var timeZone: String
    public var windows: [ScheduleWindow]

    public init(_ schedule: Schedule) {
        name = schedule.name
        timeZone = schedule.timeZone
        windows = schedule.windows
    }
}

/// Response of `PUT /api/tasks/:id`.
public struct TaskWriteResponse: Codable, Sendable {
    public var task: TaskItem
    public var scheduling: SchedulingResult
}

/// Response of `PUT /api/categories/:id`.
public struct CategoryWriteResponse: Codable, Sendable {
    public var category: Category
    public var scheduling: SchedulingResult
}

/// Response of `PUT /api/schedules/:id`.
public struct ScheduleWriteResponse: Codable, Sendable {
    public var schedule: Schedule
    public var scheduling: SchedulingResult
}

/// Response of every `DELETE /api/...` and of `PATCH /api/calendars/:id`.
public struct SchedulingResponse: Codable, Sendable {
    public var scheduling: SchedulingResult
}
