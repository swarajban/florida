import Foundation
import GRDB

// GRDB record conformances for the FloridaCore wire models. The model shapes are the table shapes:
// every stored property is a column of the same name. Dates use GRDB's default text format
// ("yyyy-MM-dd HH:mm:ss.SSS" UTC) and `Schedule.windows` is stored as a JSON text column by
// GRDB's Codable support, as are `CalendarEvent.attendees` and `organizer`, `RoutineBlock.days`,
// `allows` and `alternates`, and `PlanSummary.missed` and `capacity`. The conformances are retroactive on purpose: FloridaCore stays free of GRDB.

extension RoutineBlock: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "routineBlock"
}

extension UserSettings: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "userSettings"
}

extension Schedule: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "schedule"
}

extension TaskCategory: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "category"
}

extension TaskItem: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "task"
}

extension Placement: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "placement"
}

extension Project: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "project"
}

extension DayOverride: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "dayOverride"
}

extension ProjectPlacement: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "projectPlacement"
}

extension RoutineOccurrence: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "routineOccurrence"
}

extension PlanSummary: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "planSummary"
}

extension Brief: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "brief"
}

extension OptionalPlacement: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "optionalPlacement"
}

extension CalendarEvent: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "event"
}

extension UnscheduledTask: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "unscheduled"
}

extension GoogleAccount: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "googleAccount"
}

extension CalendarInfo: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "calendar"
}

/// A local write that has not been pushed to the server yet. The queue holds at most one row per
/// (entity, entityId); later task edits merge their intent into the earlier write.
public struct PendingWrite: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public enum Entity: String, Codable, Hashable, Sendable {
        case task, category, schedule, event, project, dayOverride, calendar
    }

    public enum Op: String, Codable, Hashable, Sendable {
        case put, patch, delete
    }

    public static let databaseTableName = "pendingWrite"

    /// Autoincremented queue position; nil until inserted.
    public var seq: Int64?
    public var entity: Entity
    public var entityId: String
    public var op: Op
    /// Full write JSON for `put`, changed task fields (including explicit nulls) for `patch`;
    /// nil for `delete`.
    public var body: Data?
    public var createdAt: Date

    public init(seq: Int64? = nil, entity: Entity, entityId: String, op: Op, body: Data?, createdAt: Date) {
        self.seq = seq
        self.entity = entity
        self.entityId = entityId
        self.op = op
        self.body = body
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        seq = inserted.rowID
    }

    /// Where a push sends this write: a `put` of a schedule, then of a category, then of a project
    /// goes ahead of every other write. A row can name any of them (a task its project, a project
    /// its category, a category its schedule), and the server refuses a name it has not seen.
    /// Queue order alone cannot promise that: saving a project again moves its write behind the
    /// task filed under it in between.
    var pushRank: Int {
        if entity == .category, op == .delete { return 1 }
        guard op != .delete else { return 3 }
        switch entity {
        case .schedule, .calendar: return 0
        case .category: return 1
        case .project: return 2
        case .task, .event, .dayOverride: return 3
        }
    }

    /// The project a queued task write files its task under, when the body names one.
    var namedProjectId: String? {
        guard entity == .task, let body, let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return fields["projectId"] as? String
    }
}

/// A scheduled piece of a task together with the task it belongs to.
public struct ScheduledBlock: Hashable, Sendable {
    public var placement: Placement
    public var task: TaskItem

    public init(placement: Placement, task: TaskItem) {
        self.placement = placement
        self.task = task
    }
}

/// Everything on the calendar for one day: visible events and scheduled task blocks. Used by the widgets.
public struct DayAgenda: Hashable, Sendable {
    /// Start of the day in the calendar it was computed for.
    public var day: Date
    public var events: [CalendarEvent]
    public var blockingAllDayEvents: [CalendarEvent]
    public var placements: [ScheduledBlock]
    /// The day's commitments (the gym) and time held for active projects, by start.
    public var planBlocks: [PlanBlock]
    /// Completed on this local day, regardless of where (or whether) they were scheduled.
    public var completedTasks: [TaskItem]

    public init(
        day: Date, events: [CalendarEvent], placements: [ScheduledBlock],
        planBlocks: [PlanBlock] = [], completedTasks: [TaskItem] = [], blockingAllDayEvents: [CalendarEvent] = []
    ) {
        self.day = day
        self.events = events
        self.blockingAllDayEvents = blockingAllDayEvents
        self.placements = placements
        self.planBlocks = planBlocks
        self.completedTasks = completedTasks
    }
}
