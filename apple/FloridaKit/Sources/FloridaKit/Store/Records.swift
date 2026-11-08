import Foundation
import GRDB

// GRDB record conformances for the FloridaCore wire models. The model shapes are the table shapes:
// every stored property is a column of the same name. Dates use GRDB's default text format
// ("yyyy-MM-dd HH:mm:ss.SSS" UTC) and `Schedule.windows` is stored as a JSON text column by
// GRDB's Codable support. The conformances are retroactive on purpose: FloridaCore stays free of GRDB.

extension Schedule: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "schedule"
}

extension Category: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "category"
}

extension TaskItem: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "task"
}

extension Placement: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "placement"
}

extension CalendarEvent: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "event"
}

extension GoogleAccount: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "googleAccount"
}

extension CalendarInfo: @retroactive FetchableRecord, @retroactive PersistableRecord {
    public static let databaseTableName = "calendar"
}

/// A local write that has not been pushed to the server yet. The queue holds at most one row per
/// (entity, entityId); a later write replaces an earlier one.
public struct PendingWrite: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public enum Entity: String, Codable, Hashable, Sendable {
        case task, category, schedule
    }

    public enum Op: String, Codable, Hashable, Sendable {
        case put, delete
    }

    public static let databaseTableName = "pendingWrite"

    /// Autoincremented queue position; nil until inserted.
    public var seq: Int64?
    public var entity: Entity
    public var entityId: String
    public var op: Op
    /// JSON of `TaskWrite` / `CategoryWrite` / `ScheduleWrite` for `put`; nil for `delete`.
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
    public var placements: [ScheduledBlock]

    public init(day: Date, events: [CalendarEvent], placements: [ScheduledBlock]) {
        self.day = day
        self.events = events
        self.placements = placements
    }
}
