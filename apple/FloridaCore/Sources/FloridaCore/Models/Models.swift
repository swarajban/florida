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

/// Where a task can be done. Each `RoutineBlock` lists the contexts it allows, so an errand is
/// never placed on an office day and office-only work never lands on a home day.
public enum TaskContext: String, Codable, Hashable, Sendable, CaseIterable {
    /// Anywhere with a laptop; the default, and what every block that allows work allows.
    case computer
    /// In person, out of the house (a UPS return, a pharmacy run).
    case errand
    /// In person, at home (assemble the crib, sort the garage).
    case home
    /// Only at the office (badge pickup, a whiteboard session).
    case office
}

/// Which side of life a category belongs to; nil for the inbox, whose tasks are unfiled.
public enum CategoryArea: String, Codable, Hashable, Sendable, CaseIterable {
    case work, personal
}

/// Where a project stands. Only an `active` project's tasks are scheduled.
public enum ProjectStatus: String, Codable, Hashable, Sendable, CaseIterable {
    /// Being worked on.
    case active
    /// An idea, not started.
    case thinking
    /// Started, then set aside.
    case onHold = "on_hold"
    case done
}

/// How much of the user a task takes. A `shared` task can run beside tasks of up to two other
/// projects (an agent does the work; the user checks in); a `full` one has its time to itself.
public enum TaskAttention: String, Codable, Hashable, Sendable, CaseIterable {
    case full, shared
}

/// What a day is, when a `DayOverride` makes it differ from its weekday's routine.
public enum DayKind: String, Codable, Hashable, Sendable, CaseIterable {
    case home, office, off
}

public enum BriefKind: String, Codable, Hashable, Sendable, CaseIterable {
    case daily, weekly
}

/// One more slot a commitment may take in a week; see `RoutineBlock.alternates`.
public struct RoutineSlot: Codable, Hashable, Sendable {
    /// 0 = Sunday … 6 = Saturday.
    public var day: Int
    /// "HH:MM", 24-hour.
    public var start: String
    public var end: String

    public init(day: Int, start: String, end: String) {
        self.day = day
        self.start = start
        self.end = end
    }
}

/// One window of the weekly routine: wall-clock hours on some weekdays, in `UserSettings.timeZone`,
/// during which tasks of the listed contexts may be scheduled. Time outside every block (sleep,
/// family) is never scheduled. An `optional` block (a weekday evening) is never planned on
/// either; the scheduler only suggests what to do there, as `OptionalPlacement`s. A block that
/// allows nothing is a commitment (the gym): nothing is planned over its `RoutineOccurrence`s.
/// Server-owned for now; clients read and show it.
public struct RoutineBlock: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Days of week the block applies to: 0 = Sunday … 6 = Saturday.
    public var days: [Int]
    /// "HH:MM", 24-hour.
    public var start: String
    /// "HH:MM", 24-hour; after `start` on the same day.
    public var end: String
    /// Empty makes the block a commitment: its time is taken and nothing is scheduled in it.
    public var allows: [TaskContext]
    /// Time the user might work but does not count on: suggested for, never planned on.
    public var optional: Bool
    /// A commitment's extra weekly occurrence: the first of these slots the calendar leaves free.
    public var alternates: [RoutineSlot]?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String, name: String, days: [Int], start: String, end: String, allows: [TaskContext],
        optional: Bool = false, alternates: [RoutineSlot]? = nil, createdAt: Date, updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.days = days
        self.start = start
        self.end = end
        self.allows = allows
        self.optional = optional
        self.alternates = alternates
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Hand-written only so `optional` can default to false when the JSON (an older server) lacks
    /// it; everything else is as synthesized.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        days = try c.decode([Int].self, forKey: .days)
        start = try c.decode(String.self, forKey: .start)
        end = try c.decode(String.self, forKey: .end)
        allows = try c.decode([TaskContext].self, forKey: .allows)
        optional = try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        alternates = try c.decodeIfPresent([RoutineSlot].self, forKey: .alternates)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    /// Time that is taken (the gym) rather than time to plan in.
    public var isCommitment: Bool { allows.isEmpty }
}

/// The user's one row of preferences; the routine's time zone lives here. Never deleted.
/// (Not `Settings`: SwiftUI exports a scene of that name on macOS.)
public struct UserSettings: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// IANA identifier the routine blocks' hours are read in, e.g. "America/Los_Angeles".
    public var timeZone: String
    public var updatedAt: Date

    public init(id: String, timeZone: String, updatedAt: Date) {
        self.id = id
        self.timeZone = timeZone
        self.updatedAt = updatedAt
    }
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
    /// Work or personal; nil for the inbox. Missing from older servers' JSON, which decodes as nil.
    public var area: CategoryArea?
    public var scheduleId: String
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String, name: String, color: String? = nil, area: CategoryArea? = nil, scheduleId: String,
        sortOrder: Int = 0, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.area = area
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
    public var source: TaskSource?
    public var durationMinutes: Int
    /// Smallest piece the scheduler may split the task into; nil means one contiguous block.
    public var minChunkMinutes: Int?
    public var priority: Priority
    public var deadlineType: DeadlineType
    public var dueAt: Date?
    public var someday: Bool
    public var startAt: Date?
    /// Overrides the category's schedule when set.
    public var scheduleId: String?
    /// Where the task can be done; the scheduler only uses routine blocks that allow it.
    public var context: TaskContext
    /// The project the task belongs to, if any. Tasks of a project that is not active are not scheduled.
    public var projectId: String?
    /// Nil follows the project: shared when it is `parallel`, else full. See `attention(in:)`.
    public var attention: TaskAttention?
    /// When set the task is fixed at this instant as one block.
    public var pinnedStart: Date?
    public var completedMinutes: Int
    public var completedAt: Date?
    public var recurrence: TaskRecurrence?
    /// Server-owned series membership and logical occurrence date (YYYY-MM-DD).
    public var recurrenceSeriesId: String?
    public var recurrenceDate: String?
    /// Server-owned concurrency token for the recurrence rule and template.
    public var recurrenceRevision: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String, categoryId: String, title: String, notes: String? = nil, durationMinutes: Int,
        minChunkMinutes: Int? = nil, priority: Priority = .medium, deadlineType: DeadlineType = .none,
        dueAt: Date? = nil, startAt: Date? = nil, scheduleId: String? = nil, context: TaskContext = .computer,
        pinnedStart: Date? = nil, completedMinutes: Int = 0, completedAt: Date? = nil, createdAt: Date,
        updatedAt: Date, deletedAt: Date? = nil, recurrence: TaskRecurrence? = nil,
        recurrenceSeriesId: String? = nil, recurrenceDate: String? = nil, recurrenceRevision: String? = nil,
        projectId: String? = nil, attention: TaskAttention? = nil, source: TaskSource? = nil, someday: Bool = false
    ) {
        self.id = id
        self.categoryId = categoryId
        self.title = title
        self.notes = notes
        self.source = source
        self.durationMinutes = durationMinutes
        self.minChunkMinutes = minChunkMinutes
        self.priority = priority
        self.deadlineType = deadlineType
        self.dueAt = dueAt
        self.someday = someday
        self.startAt = startAt
        self.scheduleId = scheduleId
        self.context = context
        self.projectId = projectId
        self.attention = attention
        self.pinnedStart = pinnedStart
        self.completedMinutes = completedMinutes
        self.completedAt = completedAt
        self.recurrence = recurrence
        self.recurrenceSeriesId = recurrenceSeriesId
        self.recurrenceDate = recurrenceDate
        self.recurrenceRevision = recurrenceRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Hand-written only so `context` can default to `.computer` when the JSON (an older server)
    /// or the row (a store that predates the column) lacks it; everything else is as synthesized.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        categoryId = try c.decode(String.self, forKey: .categoryId)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        source = try c.decodeIfPresent(TaskSource.self, forKey: .source)
        durationMinutes = try c.decode(Int.self, forKey: .durationMinutes)
        minChunkMinutes = try c.decodeIfPresent(Int.self, forKey: .minChunkMinutes)
        priority = try c.decode(Priority.self, forKey: .priority)
        deadlineType = try c.decode(DeadlineType.self, forKey: .deadlineType)
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        someday = try c.decodeIfPresent(Bool.self, forKey: .someday) ?? false
        startAt = try c.decodeIfPresent(Date.self, forKey: .startAt)
        scheduleId = try c.decodeIfPresent(String.self, forKey: .scheduleId)
        context = try c.decodeIfPresent(TaskContext.self, forKey: .context) ?? .computer
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        attention = try c.decodeIfPresent(TaskAttention.self, forKey: .attention)
        pinnedStart = try c.decodeIfPresent(Date.self, forKey: .pinnedStart)
        completedMinutes = try c.decode(Int.self, forKey: .completedMinutes)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        recurrence = try c.decodeIfPresent(TaskRecurrence.self, forKey: .recurrence)
        recurrenceSeriesId = try c.decodeIfPresent(String.self, forKey: .recurrenceSeriesId)
        recurrenceDate = try c.decodeIfPresent(String.self, forKey: .recurrenceDate)
        recurrenceRevision = try c.decodeIfPresent(String.self, forKey: .recurrenceRevision)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    public var isOpen: Bool { deletedAt == nil && completedAt == nil }
    public var needsTriage: Bool {
        categoryId == TaskCategory.inboxId || (dueAt == nil && startAt == nil && pinnedStart == nil && !someday)
    }
    public var remainingMinutes: Int { max(0, durationMinutes - completedMinutes) }

    /// The attention the scheduler plans the task with: its own, or else its project's default.
    /// A pinned task always has its time to itself.
    public func attention(in project: Project?) -> TaskAttention {
        if pinnedStart != nil { return .full }
        return attention ?? (project?.parallel == true ? .shared : .full)
    }
}

/// Ongoing work bigger than one task (an app, a migration): a status, an optional next step, and
/// the tasks filed under it. `parallel` projects can be worked side by side, up to three at once;
/// `weeklyMinutes` holds that much time for the project every week, as `ProjectPlacement`s.
public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var status: ProjectStatus
    public var categoryId: String?
    public var notes: String?
    /// The one thing to do next, in the user's words.
    public var nextStep: String?
    /// Its tasks default to shared attention, so they can run beside other parallel projects.
    public var parallel: Bool
    /// Time to hold for the project each week, beyond its tasks; nil holds none.
    public var weeklyMinutes: Int?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String, name: String, status: ProjectStatus = .active, categoryId: String? = nil, notes: String? = nil,
        nextStep: String? = nil, parallel: Bool = false, weeklyMinutes: Int? = nil, sortOrder: Int = 0,
        createdAt: Date, updatedAt: Date, deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.categoryId = categoryId
        self.notes = notes
        self.nextStep = nextStep
        self.parallel = parallel
        self.weeklyMinutes = weeklyMinutes
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// One date that departs from the weekly routine: worked from home, at the office, or not at all.
public struct DayOverride: Codable, Hashable, Sendable, Identifiable {
    /// Local date in `UserSettings.timeZone`, "YYYY-MM-DD".
    public var date: String
    public var kind: DayKind
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public var id: String { date }

    public init(date: String, kind: DayKind, note: String? = nil, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil) {
        self.date = date
        self.kind = kind
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Scheduler output for one piece of a task. Derived data; the server replaces all rows on every run.
public struct Placement: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var startAt: Date
    public var endAt: Date
    public var pinned: Bool
    /// Nil when the block has its time to itself; 0–2 when it runs beside other projects' blocks.
    public var lane: Int?
    public var computedAt: Date

    public init(
        id: String, taskId: String, startAt: Date, endAt: Date, pinned: Bool, lane: Int? = nil, computedAt: Date
    ) {
        self.id = id
        self.taskId = taskId
        self.startAt = startAt
        self.endAt = endAt
        self.pinned = pinned
        self.lane = lane
        self.computedAt = computedAt
    }
}

/// Scheduler output: time held for a project's weekly budget. No task is behind it. Derived data;
/// the server replaces all rows on every run.
public struct ProjectPlacement: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var projectId: String
    /// Local date of the Sunday starting the week whose budget the block draws on, "YYYY-MM-DD".
    public var weekOf: String
    public var startAt: Date
    public var endAt: Date
    /// As `Placement.lane`.
    public var lane: Int?
    public var computedAt: Date

    public init(
        id: String, projectId: String, weekOf: String, startAt: Date, endAt: Date, lane: Int? = nil, computedAt: Date
    ) {
        self.id = id
        self.projectId = projectId
        self.weekOf = weekOf
        self.startAt = startAt
        self.endAt = endAt
        self.lane = lane
        self.computedAt = computedAt
    }
}

/// Scheduler output: where one occurrence of a commitment (the gym) lands. Derived data; the
/// server replaces all rows on every run.
public struct RoutineOccurrence: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// The commitment `RoutineBlock`.
    public var blockId: String
    public var startAt: Date
    public var endAt: Date
    public var computedAt: Date

    public init(id: String, blockId: String, startAt: Date, endAt: Date, computedAt: Date) {
        self.id = id
        self.blockId = blockId
        self.startAt = startAt
        self.endAt = endAt
        self.computedAt = computedAt
    }
}

/// A week in which none of a commitment's alternate slots was free.
public struct MissedCommitment: Codable, Hashable, Sendable {
    public var blockId: String
    /// Local date of the Sunday that starts the week, "YYYY-MM-DD".
    public var weekOf: String

    public init(blockId: String, weekOf: String) {
        self.blockId = blockId
        self.weekOf = weekOf
    }
}

/// Time still open on one local day after the plan, per task context.
public struct DayCapacity: Codable, Hashable, Sendable {
    public struct FreeMinutes: Codable, Hashable, Sendable {
        public var computer: Int
        public var errand: Int
        public var home: Int
        public var office: Int

        public init(computer: Int = 0, errand: Int = 0, home: Int = 0, office: Int = 0) {
            self.computer = computer
            self.errand = errand
            self.home = home
            self.office = office
        }

        public subscript(context: TaskContext) -> Int {
            switch context {
            case .computer: computer
            case .errand: errand
            case .home: home
            case .office: office
            }
        }
    }

    /// Local date in `UserSettings.timeZone`, "YYYY-MM-DD".
    public var date: String
    public var freeMinutes: FreeMinutes

    public init(date: String, freeMinutes: FreeMinutes) {
        self.date = date
        self.freeMinutes = freeMinutes
    }
}

/// What the last scheduler run says about the plan as a whole. One row, replaced on every run.
public struct PlanSummary: Codable, Hashable, Sendable {
    public var missed: [MissedCommitment]
    public var capacity: [DayCapacity]

    public init(missed: [MissedCommitment] = [], capacity: [DayCapacity] = []) {
        self.missed = missed
        self.capacity = capacity
    }
}

/// Claude's words about a plan the scheduler already made: the day's brief or the week's review.
/// Server-written; the newest of each kind is synced.
public struct Brief: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: BriefKind
    /// The local day (daily) or the Sunday starting the week (weekly), "YYYY-MM-DD".
    public var date: String
    public var headline: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, kind: BriefKind, date: String, headline: String, body: String, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.headline = headline
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Scheduler output: what to do in an optional routine block (an evening) if the user chooses to
/// work then. A suggestion, not the plan: the task keeps its `Placement`s, and the same task may be
/// suggested for several blocks. Derived data; the server replaces all rows on every run.
public struct OptionalPlacement: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    /// The optional `RoutineBlock` the suggestion sits in.
    public var blockId: String
    public var startAt: Date
    public var endAt: Date
    public var computedAt: Date

    public init(id: String, taskId: String, blockId: String, startAt: Date, endAt: Date, computedAt: Date) {
        self.id = id
        self.taskId = taskId
        self.blockId = blockId
        self.startAt = startAt
        self.endAt = endAt
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
    public var blocksDay: Bool?
    public var autoBlocksDay: Bool?
    public var blockingReason: String?
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
        icalUid: String? = nil, updatedAt: Date, deletedAt: Date? = nil, blocksDay: Bool? = nil,
        autoBlocksDay: Bool? = nil, blockingReason: String? = nil
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
        self.blocksDay = blocksDay
        self.autoBlocksDay = autoBlocksDay
        self.blockingReason = blockingReason
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
        blocksDay = try container.decodeIfPresent(Bool.self, forKey: .blocksDay)
        autoBlocksDay = try container.decodeIfPresent(Bool.self, forKey: .autoBlocksDay)
        blockingReason = try container.decodeIfPresent(String.self, forKey: .blockingReason)
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
            while let junk = trailingJunk(of: link) {
                link.removeLast(junk)
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

    /// Characters to drop from the end of `link`: prose punctuation, or an HTML entity remnant an
    /// HTML description glued to the URL ("…/j/123&nbsp;", "…/x&amp;").
    private static func trailingJunk(of link: String) -> Int? {
        if let last = link.last, ".,;:!?".contains(last) { return 1 }
        guard let amp = link.lastIndex(of: "&") else { return nil }
        let name = link[link.index(after: amp)...]
        let named = (2...8).contains(name.count) && name.allSatisfy(\.isLetter)
        let numeric = name.first == "#" && name.count > 1 && name.dropFirst().allSatisfy(\.isNumber)
        return named || numeric ? name.count + 1 : nil
    }
}

/// A connected Google account, without any tokens.
public struct GoogleAccount: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var email: String
    /// Short slug such as "work" or "personal".
    public var label: String
    public var displayName: String?
    public var updatedAt: Date

    public init(id: String, email: String, label: String, updatedAt: Date, displayName: String? = nil) {
        self.id = id
        self.email = email
        self.label = label
        self.displayName = displayName
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
    /// Whether events from this calendar are visible.
    public var selected: Bool
    public var blocksScheduling: Bool
    public var updatedAt: Date

    public init(
        id: String, accountId: String, googleId: String, summary: String, color: String? = nil,
        accessRole: String, selected: Bool, blocksScheduling: Bool = true, updatedAt: Date
    ) {
        self.id = id
        self.accountId = accountId
        self.googleId = googleId
        self.summary = summary
        self.color = color
        self.accessRole = accessRole
        self.selected = selected
        self.blocksScheduling = blocksScheduling
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountId, googleId, summary, color, accessRole, selected, blocksScheduling, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        accountId = try container.decode(String.self, forKey: .accountId)
        googleId = try container.decode(String.self, forKey: .googleId)
        summary = try container.decode(String.self, forKey: .summary)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        accessRole = try container.decode(String.self, forKey: .accessRole)
        selected = try container.decode(Bool.self, forKey: .selected)
        blocksScheduling = try container.decodeIfPresent(Bool.self, forKey: .blocksScheduling) ?? true
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

/// A task the last scheduler run could not fully place. Derived data; the server sends the whole
/// list with every sync, like placements.
public struct UnscheduledTask: Codable, Hashable, Sendable, Identifiable {
    public var taskId: String
    /// "no_fit_in_horizon", "no_fit_before_hard_deadline", "unknown_schedule", or
    /// "no_allowed_block" (no routine block allows the task's context).
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

/// `GET /api/sync?since=` response. `routineBlocks`, `schedules`, `categories`, `projects`,
/// `dayOverrides`, `tasks` and `events` contain rows changed after `since`, including tombstones
/// (`deletedAt` set). `settings` (nil before the server is seeded), `placements`,
/// `optionalPlacements`, `unscheduled`, `projectPlacements`, `routineOccurrences`, `missed`,
/// `capacity`, `briefs`, `accounts` and `calendars` are always complete and are meant to be
/// replaced wholesale. Every key added after the first release decodes as empty when an older
/// server omits it.
public struct SyncResponse: Codable, Sendable {
    /// Server time when the diff was taken; pass back as the next `since`.
    public var cursor: String
    /// Nil when the server predates settings or has not been seeded.
    public var settings: UserSettings?
    /// Empty when the server predates the routine.
    public var routineBlocks: [RoutineBlock]
    public var schedules: [Schedule]
    public var categories: [TaskCategory]
    public var tasks: [TaskItem]
    public var events: [CalendarEvent]
    public var placements: [Placement]
    /// Suggestions for optional routine blocks; empty when the server predates them.
    public var optionalPlacements: [OptionalPlacement]
    public var accounts: [GoogleAccount]
    public var calendars: [CalendarInfo]
    /// Empty when the server predates the field.
    public var unscheduled: [UnscheduledTask]
    public var projects: [Project]
    public var dayOverrides: [DayOverride]
    public var projectPlacements: [ProjectPlacement]
    public var routineOccurrences: [RoutineOccurrence]
    public var missed: [MissedCommitment]
    public var capacity: [DayCapacity]
    /// The newest daily brief and weekly review; empty until the server has written one.
    public var briefs: [Brief]

    public init(
        cursor: String, settings: UserSettings? = nil, routineBlocks: [RoutineBlock] = [],
        schedules: [Schedule] = [], categories: [TaskCategory] = [], tasks: [TaskItem] = [],
        events: [CalendarEvent] = [], placements: [Placement] = [], optionalPlacements: [OptionalPlacement] = [],
        accounts: [GoogleAccount] = [], calendars: [CalendarInfo] = [], unscheduled: [UnscheduledTask] = [],
        projects: [Project] = [], dayOverrides: [DayOverride] = [], projectPlacements: [ProjectPlacement] = [],
        routineOccurrences: [RoutineOccurrence] = [], missed: [MissedCommitment] = [], capacity: [DayCapacity] = [],
        briefs: [Brief] = []
    ) {
        self.cursor = cursor
        self.settings = settings
        self.routineBlocks = routineBlocks
        self.schedules = schedules
        self.categories = categories
        self.tasks = tasks
        self.events = events
        self.placements = placements
        self.optionalPlacements = optionalPlacements
        self.accounts = accounts
        self.calendars = calendars
        self.unscheduled = unscheduled
        self.projects = projects
        self.dayOverrides = dayOverrides
        self.projectPlacements = projectPlacements
        self.routineOccurrences = routineOccurrences
        self.missed = missed
        self.capacity = capacity
        self.briefs = briefs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decode(String.self, forKey: .cursor)
        settings = try container.decodeIfPresent(UserSettings.self, forKey: .settings)
        routineBlocks = try container.decodeIfPresent([RoutineBlock].self, forKey: .routineBlocks) ?? []
        schedules = try container.decode([Schedule].self, forKey: .schedules)
        categories = try container.decode([TaskCategory].self, forKey: .categories)
        tasks = try container.decode([TaskItem].self, forKey: .tasks)
        events = try container.decode([CalendarEvent].self, forKey: .events)
        placements = try container.decode([Placement].self, forKey: .placements)
        optionalPlacements = try container.decodeIfPresent([OptionalPlacement].self, forKey: .optionalPlacements) ?? []
        accounts = try container.decode([GoogleAccount].self, forKey: .accounts)
        calendars = try container.decode([CalendarInfo].self, forKey: .calendars)
        unscheduled = try container.decodeIfPresent([UnscheduledTask].self, forKey: .unscheduled) ?? []
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        dayOverrides = try container.decodeIfPresent([DayOverride].self, forKey: .dayOverrides) ?? []
        projectPlacements = try container.decodeIfPresent([ProjectPlacement].self, forKey: .projectPlacements) ?? []
        routineOccurrences = try container.decodeIfPresent([RoutineOccurrence].self, forKey: .routineOccurrences) ?? []
        missed = try container.decodeIfPresent([MissedCommitment].self, forKey: .missed) ?? []
        capacity = try container.decodeIfPresent([DayCapacity].self, forKey: .capacity) ?? []
        briefs = try container.decodeIfPresent([Brief].self, forKey: .briefs) ?? []
    }

    public var planSummary: PlanSummary { PlanSummary(missed: missed, capacity: capacity) }
}

/// The scheduler's result as returned by every mutating API call (`scheduling`) and `POST /api/schedule/run`.
public struct SchedulingResult: Codable, Hashable, Sendable {
    public struct Piece: Codable, Hashable, Sendable {
        public var taskId: String
        public var start: Date
        public var end: Date
        public var pinned: Bool
        /// As `Placement.lane`.
        public var lane: Int?

        public init(taskId: String, start: Date, end: Date, pinned: Bool, lane: Int? = nil) {
            self.taskId = taskId
            self.start = start
            self.end = end
            self.pinned = pinned
            self.lane = lane
        }
    }

    public struct Unscheduled: Codable, Hashable, Sendable {
        public var taskId: String
        /// "no_fit_in_horizon", "no_fit_before_hard_deadline", "unknown_schedule", or "no_allowed_block".
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

    /// A suggestion for an optional routine block; see `OptionalPlacement`.
    public struct Suggestion: Codable, Hashable, Sendable {
        public var taskId: String
        public var blockId: String
        public var start: Date
        public var end: Date

        public init(taskId: String, blockId: String, start: Date, end: Date) {
            self.taskId = taskId
            self.blockId = blockId
            self.start = start
            self.end = end
        }
    }

    /// One occurrence of a commitment; see `RoutineOccurrence`.
    public struct Occurrence: Codable, Hashable, Sendable {
        public var blockId: String
        public var start: Date
        public var end: Date

        public init(blockId: String, start: Date, end: Date) {
            self.blockId = blockId
            self.start = start
            self.end = end
        }
    }

    /// Time held for a project; see `ProjectPlacement`.
    public struct ProjectPiece: Codable, Hashable, Sendable {
        public var projectId: String
        public var weekOf: String
        public var start: Date
        public var end: Date
        public var lane: Int?

        public init(projectId: String, weekOf: String, start: Date, end: Date, lane: Int? = nil) {
            self.projectId = projectId
            self.weekOf = weekOf
            self.start = start
            self.end = end
            self.lane = lane
        }
    }

    public var placements: [Piece]
    public var unscheduled: [Unscheduled]
    public var late: [Late]
    /// Suggestions for optional blocks, never part of `placements`; empty from an older server.
    public var optional: [Suggestion]
    /// Where the commitments land. This and the three below are empty from an older server.
    public var routine: [Occurrence]
    public var missed: [MissedCommitment]
    public var capacity: [DayCapacity]
    public var projectPlacements: [ProjectPiece]

    public init(
        placements: [Piece] = [], unscheduled: [Unscheduled] = [], late: [Late] = [], optional: [Suggestion] = [],
        routine: [Occurrence] = [], missed: [MissedCommitment] = [], capacity: [DayCapacity] = [],
        projectPlacements: [ProjectPiece] = []
    ) {
        self.placements = placements
        self.unscheduled = unscheduled
        self.late = late
        self.optional = optional
        self.routine = routine
        self.missed = missed
        self.capacity = capacity
        self.projectPlacements = projectPlacements
    }

    /// Hand-written only so the keys added after the first release default to empty when an
    /// older server omits them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        placements = try c.decode([Piece].self, forKey: .placements)
        unscheduled = try c.decode([Unscheduled].self, forKey: .unscheduled)
        late = try c.decode([Late].self, forKey: .late)
        optional = try c.decodeIfPresent([Suggestion].self, forKey: .optional) ?? []
        routine = try c.decodeIfPresent([Occurrence].self, forKey: .routine) ?? []
        missed = try c.decodeIfPresent([MissedCommitment].self, forKey: .missed) ?? []
        capacity = try c.decodeIfPresent([DayCapacity].self, forKey: .capacity) ?? []
        projectPlacements = try c.decodeIfPresent([ProjectPiece].self, forKey: .projectPlacements) ?? []
    }

    public var planSummary: PlanSummary { PlanSummary(missed: missed, capacity: capacity) }

    /// The unscheduled tasks as `UnscheduledTask` rows, as `/api/sync` serves them after this run.
    public func unscheduledRows(computedAt: Date) -> [UnscheduledTask] {
        unscheduled.map {
            UnscheduledTask(taskId: $0.taskId, reason: $0.reason, unplacedMinutes: $0.unplacedMinutes, computedAt: computedAt)
        }
    }

    /// Converts the pieces into `Placement` rows, as the server stores them after this run.
    public func placementRows(computedAt: Date, makeId: () -> String = { UUID().uuidString.lowercased() }) -> [Placement] {
        placements.map {
            Placement(
                id: makeId(), taskId: $0.taskId, startAt: $0.start, endAt: $0.end, pinned: $0.pinned, lane: $0.lane,
                computedAt: computedAt)
        }
    }

    /// Converts the held project time into `ProjectPlacement` rows, as the server stores them after this run.
    public func projectPlacementRows(
        computedAt: Date, makeId: () -> String = { UUID().uuidString.lowercased() }
    ) -> [ProjectPlacement] {
        projectPlacements.map {
            ProjectPlacement(
                id: makeId(), projectId: $0.projectId, weekOf: $0.weekOf, startAt: $0.start, endAt: $0.end,
                lane: $0.lane, computedAt: computedAt)
        }
    }

    /// Converts the commitments' occurrences into `RoutineOccurrence` rows, as the server stores them after this run.
    public func routineOccurrenceRows(
        computedAt: Date, makeId: () -> String = { UUID().uuidString.lowercased() }
    ) -> [RoutineOccurrence] {
        routine.map {
            RoutineOccurrence(id: makeId(), blockId: $0.blockId, startAt: $0.start, endAt: $0.end, computedAt: computedAt)
        }
    }

    /// Converts the suggestions into `OptionalPlacement` rows, as the server stores them after this run.
    public func optionalPlacementRows(
        computedAt: Date, makeId: () -> String = { UUID().uuidString.lowercased() }
    ) -> [OptionalPlacement] {
        optional.map {
            OptionalPlacement(
                id: makeId(), taskId: $0.taskId, blockId: $0.blockId, startAt: $0.start, endAt: $0.end,
                computedAt: computedAt)
        }
    }
}

/// Body of `PUT /api/tasks/:id`.
public struct TaskWrite: Codable, Hashable, Sendable {
    public var categoryId: String
    public var title: String
    public var notes: String?
    public var source: TaskSource?
    public var durationMinutes: Int
    public var minChunkMinutes: Int?
    public var priority: Priority
    public var deadlineType: DeadlineType
    public var dueAt: Date?
    public var someday: Bool?
    public var startAt: Date?
    public var scheduleId: String?
    public var context: TaskContext
    /// Left out when nil, which the server reads as "keep"; an edit that clears either sends an
    /// explicit null through the changed-fields PATCH (`AppDatabase.saveTask`).
    public var projectId: String?
    public var attention: TaskAttention?
    public var pinnedStart: Date?
    public var completedMinutes: Int
    public var completedAt: Date?
    public var recurrence: TaskRecurrence?
    /// The revision the user edited, including nil when the task was not in a series.
    public var expectedRecurrenceRevision: String?

    public init(_ task: TaskItem) {
        categoryId = task.categoryId
        title = task.title
        notes = task.notes
        source = task.source
        durationMinutes = task.durationMinutes
        minChunkMinutes = task.minChunkMinutes
        priority = task.priority
        deadlineType = task.deadlineType
        dueAt = task.dueAt
        someday = task.someday
        startAt = task.startAt
        scheduleId = task.scheduleId
        context = task.context
        projectId = task.projectId
        attention = task.attention
        pinnedStart = task.pinnedStart
        completedMinutes = task.completedMinutes
        completedAt = task.completedAt
        recurrence = task.recurrence
        expectedRecurrenceRevision = task.recurrenceRevision
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(categoryId, forKey: .categoryId)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(source, forKey: .source)
        try container.encode(durationMinutes, forKey: .durationMinutes)
        try container.encodeIfPresent(minChunkMinutes, forKey: .minChunkMinutes)
        try container.encode(priority, forKey: .priority)
        try container.encode(deadlineType, forKey: .deadlineType)
        try container.encodeIfPresent(dueAt, forKey: .dueAt)
        try container.encodeIfPresent(someday, forKey: .someday)
        try container.encodeIfPresent(startAt, forKey: .startAt)
        try container.encodeIfPresent(scheduleId, forKey: .scheduleId)
        try container.encode(context, forKey: .context)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encodeIfPresent(attention, forKey: .attention)
        try container.encodeIfPresent(pinnedStart, forKey: .pinnedStart)
        try container.encode(completedMinutes, forKey: .completedMinutes)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        // Unlike the other optional fields, nil explicitly stops an existing series.
        try container.encode(recurrence, forKey: .recurrence)
        try container.encode(expectedRecurrenceRevision, forKey: .expectedRecurrenceRevision)
    }
}

/// Body of `PUT /api/categories/:id`. A nil `area` is left out, and the server keeps the stored area
/// when the key is missing. That is deliberate while no client edits areas: a row saved before the
/// first sync after an upgrade has no area yet, and sending null would erase the server's.
public struct CategoryWrite: Codable, Hashable, Sendable {
    public var name: String
    public var color: String?
    public var area: CategoryArea?
    public var scheduleId: String
    public var sortOrder: Int

    public init(_ category: TaskCategory) {
        name = category.name
        color = category.color
        area = category.area
        scheduleId = category.scheduleId
        sortOrder = category.sortOrder
    }
}

/// Body of `PUT /api/projects/:id`. A nil optional field is left out, which the server reads as cleared.
public struct ProjectWrite: Codable, Hashable, Sendable {
    public var name: String
    public var status: ProjectStatus
    public var categoryId: String?
    public var notes: String?
    public var nextStep: String?
    public var parallel: Bool
    public var weeklyMinutes: Int?
    public var sortOrder: Int

    public init(_ project: Project) {
        name = project.name
        status = project.status
        categoryId = project.categoryId
        notes = project.notes
        nextStep = project.nextStep
        parallel = project.parallel
        weeklyMinutes = project.weeklyMinutes
        sortOrder = project.sortOrder
    }
}

/// Body of `PUT /api/day-overrides/:date`.
public struct DayOverrideWrite: Codable, Hashable, Sendable {
    public var kind: DayKind
    public var note: String?

    public init(_ override: DayOverride) {
        kind = override.kind
        note = override.note
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

/// Creation-only recurrence for Google events. Instances remain ordinary CalendarEvent rows.
public struct EventRecurrence: Codable, Hashable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable {
        case daily, weekly, monthly, yearly
    }

    public var frequency: Frequency
    public var interval: Int
    public var timeZone: String
    public var count: Int?

    public init(frequency: Frequency, interval: Int = 1, timeZone: String, count: Int? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.timeZone = timeZone
        self.count = count
    }
}

/// Body of `PUT /api/events/:id`. Creating an event is a `PUT` of a client-made id; the server
/// writes it to Google and fills in `googleId`. Nil `location` and `description` are omitted from
/// the JSON, like `TaskWrite`'s optionals.
public struct EventWrite: Codable, Hashable, Sendable {
    /// What a new time on one instance of a repeating event moves.
    public enum Scope: String, Codable, Hashable, Sendable {
        /// The instance alone.
        case instance
        /// Every instance: the series takes the time of day and length of this body, and each
        /// instance keeps its day.
        case series
    }

    public var calendarId: String
    public var summary: String
    public var location: String?
    public var description: String?
    public var startAt: Date
    public var endAt: Date
    public var allDay: Bool
    /// The user's own response: "accepted", "declined", "tentative" or "needsAction".
    public var responseStatus: String?
    public var recurrence: EventRecurrence?
    /// Nil, which the JSON omits, moves the instance alone.
    public var scope: Scope?
    public var blocksDay: Bool?

    public init(
        calendarId: String, summary: String, location: String? = nil, description: String? = nil,
        startAt: Date, endAt: Date, allDay: Bool, responseStatus: String? = nil,
        recurrence: EventRecurrence? = nil, scope: Scope? = nil, blocksDay: Bool? = nil
    ) {
        self.calendarId = calendarId
        self.summary = summary
        self.location = location
        self.description = description
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.responseStatus = responseStatus
        self.recurrence = recurrence
        self.scope = scope
        self.blocksDay = blocksDay
    }

    /// The body for an existing row, or nil for a row without `startAt` or `endAt` (Google omits
    /// them on some cancelled instances): the server requires both, so there is no valid body to send.
    public init?(_ event: CalendarEvent) {
        guard let startAt = event.startAt, let endAt = event.endAt else { return nil }
        calendarId = event.calendarId
        summary = event.summary ?? ""
        location = event.location
        description = event.description
        self.startAt = startAt
        self.endAt = endAt
        allDay = event.allDay
        blocksDay = event.blocksDay
        responseStatus = event.responseStatus
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(calendarId, forKey: .calendarId)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(startAt, forKey: .startAt)
        try container.encode(endAt, forKey: .endAt)
        try container.encode(allDay, forKey: .allDay)
        try container.encodeIfPresent(responseStatus, forKey: .responseStatus)
        try container.encodeIfPresent(recurrence, forKey: .recurrence)
        try container.encodeIfPresent(scope, forKey: .scope)
        try container.encode(blocksDay, forKey: .blocksDay)
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

/// Response of `PUT /api/projects/:id`.
public struct ProjectWriteResponse: Codable, Sendable {
    public var project: Project
    public var scheduling: SchedulingResult
}

/// Response of `PUT /api/day-overrides/:date`.
public struct DayOverrideWriteResponse: Codable, Sendable {
    public var dayOverride: DayOverride
    public var scheduling: SchedulingResult
}

/// Response of `PUT /api/schedules/:id`.
public struct ScheduleWriteResponse: Codable, Sendable {
    public var schedule: Schedule
    public var scheduling: SchedulingResult
}

/// Response of `PUT /api/events/:id`: the stored event as `/api/sync` serializes it.
public struct EventWriteResponse: Codable, Sendable {
    public var event: CalendarEvent
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
    public var context: TaskContext?
    public var projectId: String?
    public var attention: TaskAttention?
    /// One sentence on how the text was read, for the UI to show next to the draft.
    public var rationale: String

    public init(
        title: String, notes: String? = nil, durationMinutes: Int, minChunkMinutes: Int? = nil,
        priority: Priority = .medium, deadlineType: DeadlineType = .none, dueAt: Date? = nil, startAt: Date? = nil,
        pinnedStart: Date? = nil, categoryId: String? = nil, rationale: String = "",
        context: TaskContext? = nil, projectId: String? = nil, attention: TaskAttention? = nil
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
        self.context = context
        self.projectId = projectId
        self.attention = attention
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
