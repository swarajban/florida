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

public struct TaskCategory: Codable, Hashable, Sendable, Identifiable {
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

    /// Id of the permanent category new tasks land in. The server refuses to delete or rename it,
    /// and moves a deleted category's tasks into it.
    public static let inboxId = "inbox"

    public var isInbox: Bool { id == Self.inboxId }
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

/// A guest on a Google Calendar event.
public struct EventAttendee: Codable, Hashable, Sendable {
    public var email: String
    public var displayName: String?
    /// "needsAction", "declined", "tentative", or "accepted".
    public var responseStatus: String
    public var organizer: Bool
    /// Whether this attendee is the calendar's owner (JSON key "self").
    public var isSelf: Bool
    public var optional: Bool

    public init(
        email: String, displayName: String? = nil, responseStatus: String = "needsAction", organizer: Bool = false,
        isSelf: Bool = false, optional: Bool = false
    ) {
        self.email = email
        self.displayName = displayName
        self.responseStatus = responseStatus
        self.organizer = organizer
        self.isSelf = isSelf
        self.optional = optional
    }

    enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus, organizer, optional
        case isSelf = "self"
    }
}

/// The organizer of a Google Calendar event.
public struct EventOrganizer: Codable, Hashable, Sendable {
    public var email: String
    public var displayName: String?
    /// Whether the calendar's owner organizes the event (JSON key "self").
    public var isSelf: Bool

    public init(email: String, displayName: String? = nil, isSelf: Bool = false) {
        self.email = email
        self.displayName = displayName
        self.isSelf = isSelf
    }

    enum CodingKeys: String, CodingKey {
        case email, displayName
        case isSelf = "self"
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
    /// Google's event description; may contain HTML.
    public var description: String?
    /// The Meet/Zoom/… entry point Google attached to the event, if any.
    public var conferenceUrl: String?
    public var attendees: [EventAttendee]?
    public var organizer: EventOrganizer?
    /// Google's eventType: "default", "outOfOffice", "focusTime", "workingLocation", ….
    public var eventType: String?
    /// Id of the recurring series this instance belongs to.
    public var recurringEventId: String?
    public var icalUid: String?
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String, calendarId: String, googleId: String, status: String = "confirmed", summary: String? = nil,
        location: String? = nil, startAt: Date? = nil, endAt: Date? = nil, allDay: Bool = false,
        transparency: String? = nil, responseStatus: String? = nil, htmlLink: String? = nil,
        description: String? = nil, conferenceUrl: String? = nil, attendees: [EventAttendee]? = nil,
        organizer: EventOrganizer? = nil, eventType: String? = nil, recurringEventId: String? = nil,
        icalUid: String? = nil, updatedAt: Date, deletedAt: Date? = nil
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
        self.description = description
        self.conferenceUrl = conferenceUrl
        self.attendees = attendees
        self.organizer = organizer
        self.eventType = eventType
        self.recurringEventId = recurringEventId
        self.icalUid = icalUid
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Fields added after the first release are decoded only when present, so rows from an older
    /// server (or an older local store) still decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        calendarId = try container.decode(String.self, forKey: .calendarId)
        googleId = try container.decode(String.self, forKey: .googleId)
        status = try container.decode(String.self, forKey: .status)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        startAt = try container.decodeIfPresent(Date.self, forKey: .startAt)
        endAt = try container.decodeIfPresent(Date.self, forKey: .endAt)
        allDay = try container.decode(Bool.self, forKey: .allDay)
        transparency = try container.decodeIfPresent(String.self, forKey: .transparency)
        responseStatus = try container.decodeIfPresent(String.self, forKey: .responseStatus)
        htmlLink = try container.decodeIfPresent(String.self, forKey: .htmlLink)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        conferenceUrl = try container.decodeIfPresent(String.self, forKey: .conferenceUrl)
        attendees = try container.decodeIfPresent([EventAttendee].self, forKey: .attendees)
        organizer = try container.decodeIfPresent(EventOrganizer.self, forKey: .organizer)
        eventType = try container.decodeIfPresent(String.self, forKey: .eventType)
        recurringEventId = try container.decodeIfPresent(String.self, forKey: .recurringEventId)
        icalUid = try container.decodeIfPresent(String.self, forKey: .icalUid)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    /// Whether the event occupies time on the calendar: live, timed, not declined.
    public var isVisible: Bool {
        deletedAt == nil && status != "cancelled" && responseStatus != "declined"
    }

    public var isOutOfOffice: Bool { eventType == "outOfOffice" }

    /// Where to join the meeting: `conferenceUrl` when Google attached one, else the first Meet,
    /// Zoom, Teams or Webex link in the location, then in the description.
    public var joinURL: URL? {
        if let conferenceUrl, let url = URL(string: conferenceUrl.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }
        for text in [location, description].compactMap(\.self) {
            if let url = MeetingLink.first(in: text) {
                return url
            }
        }
        return nil
    }
}

/// Finds video-meeting links in free text such as an event's location or (HTML) description.
enum MeetingLink {
    static let hosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "webex.com"]

    /// Characters that end a URL in prose or HTML.
    private static let terminators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>()[]{}"))

    static func first(in text: String) -> URL? {
        var searchStart = text.startIndex
        while let match = text.range(of: "http", options: .caseInsensitive, range: searchStart..<text.endIndex) {
            searchStart = match.upperBound
            let end = text[match.lowerBound...].firstIndex { $0.unicodeScalars.contains(where: terminators.contains) }
                ?? text.endIndex
            var link = String(text[match.lowerBound..<end])
            while let last = link.last, ".,;:!?".contains(last) {
                link.removeLast()
            }
            let lowered = link.lowercased()
            guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://"),
                  let url = URL(string: link), let host = url.host?.lowercased()
            else { continue }
            if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return url
            }
        }
        return nil
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

/// A task the last scheduler run could not fully place. Derived data; the server sends the whole
/// list with every sync, like placements.
public struct UnscheduledTask: Codable, Hashable, Sendable, Identifiable {
    public var taskId: String
    /// "no_fit_in_horizon", "no_fit_before_hard_deadline", or "unknown_schedule".
    public var reason: String
    public var unplacedMinutes: Int
    public var computedAt: Date

    public var id: String { taskId }

    public init(taskId: String, reason: String, unplacedMinutes: Int, computedAt: Date) {
        self.taskId = taskId
        self.reason = reason
        self.unplacedMinutes = unplacedMinutes
        self.computedAt = computedAt
    }
}

// MARK: - API payloads

/// `GET /api/sync?since=` response. `schedules`, `categories`, `tasks` and `events` contain rows changed
/// after `since`, including tombstones (`deletedAt` set). `placements`, `unscheduled`, `accounts`
/// and `calendars` are always the complete tables and are meant to be replaced wholesale.
public struct SyncResponse: Codable, Sendable {
    /// Server time when the diff was taken; pass back as the next `since`.
    public var cursor: String
    public var schedules: [Schedule]
    public var categories: [TaskCategory]
    public var tasks: [TaskItem]
    public var events: [CalendarEvent]
    public var placements: [Placement]
    public var accounts: [GoogleAccount]
    public var calendars: [CalendarInfo]
    /// Empty when the server predates the field.
    public var unscheduled: [UnscheduledTask]

    public init(
        cursor: String, schedules: [Schedule] = [], categories: [TaskCategory] = [], tasks: [TaskItem] = [],
        events: [CalendarEvent] = [], placements: [Placement] = [], accounts: [GoogleAccount] = [],
        calendars: [CalendarInfo] = [], unscheduled: [UnscheduledTask] = []
    ) {
        self.cursor = cursor
        self.schedules = schedules
        self.categories = categories
        self.tasks = tasks
        self.events = events
        self.placements = placements
        self.accounts = accounts
        self.calendars = calendars
        self.unscheduled = unscheduled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decode(String.self, forKey: .cursor)
        schedules = try container.decode([Schedule].self, forKey: .schedules)
        categories = try container.decode([TaskCategory].self, forKey: .categories)
        tasks = try container.decode([TaskItem].self, forKey: .tasks)
        events = try container.decode([CalendarEvent].self, forKey: .events)
        placements = try container.decode([Placement].self, forKey: .placements)
        accounts = try container.decode([GoogleAccount].self, forKey: .accounts)
        calendars = try container.decode([CalendarInfo].self, forKey: .calendars)
        unscheduled = try container.decodeIfPresent([UnscheduledTask].self, forKey: .unscheduled) ?? []
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

    /// The unscheduled tasks as `UnscheduledTask` rows, as `/api/sync` serves them after this run.
    public func unscheduledRows(computedAt: Date) -> [UnscheduledTask] {
        unscheduled.map {
            UnscheduledTask(taskId: $0.taskId, reason: $0.reason, unplacedMinutes: $0.unplacedMinutes, computedAt: computedAt)
        }
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

    public init(_ category: TaskCategory) {
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
    public var category: TaskCategory
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

/// A task as the server's AI read a line of text (`POST /api/ai/parse-task`). Not stored: the client
/// shows it for review and saves the accepted version as a `TaskItem`.
public struct TaskDraft: Codable, Hashable, Sendable {
    public var title: String
    public var notes: String?
    public var durationMinutes: Int
    public var minChunkMinutes: Int?
    public var priority: Priority
    public var deadlineType: DeadlineType
    public var dueAt: Date?
    public var startAt: Date?
    public var pinnedStart: Date?
    /// One of the live categories, or nil when none fits.
    public var categoryId: String?
    /// One sentence on how the text was read, for the UI to show next to the draft.
    public var rationale: String

    public init(
        title: String, notes: String? = nil, durationMinutes: Int, minChunkMinutes: Int? = nil,
        priority: Priority = .medium, deadlineType: DeadlineType = .none, dueAt: Date? = nil, startAt: Date? = nil,
        pinnedStart: Date? = nil, categoryId: String? = nil, rationale: String = ""
    ) {
        self.title = title
        self.notes = notes
        self.durationMinutes = durationMinutes
        self.minChunkMinutes = minChunkMinutes
        self.priority = priority
        self.deadlineType = deadlineType
        self.dueAt = dueAt
        self.startAt = startAt
        self.pinnedStart = pinnedStart
        self.categoryId = categoryId
        self.rationale = rationale
    }
}

/// Response of `POST /api/ai/suggest-category`.
public struct CategorySuggestion: Codable, Hashable, Sendable {
    /// One of the live categories, or nil when none fits.
    public var categoryId: String?
    public var rationale: String

    public init(categoryId: String?, rationale: String) {
        self.categoryId = categoryId
        self.rationale = rationale
    }
}
