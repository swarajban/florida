import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SyncError: Error, Sendable {
    /// A non-2xx response other than 401.
    case http(status: Int, body: String)
    /// The server rejected the bearer token.
    case unauthorized
    /// The request never got a response.
    case transport(any Error)
    /// The response was 2xx but its body was not the expected JSON.
    case decoding(any Error)
}

/// A queued write the server refused with a 4xx. It has left the queue because retrying could
/// never succeed, and the local row has been reset to the server's copy (removed when the server
/// has it tombstoned or never had it).
public struct RejectedWrite: Hashable, Sendable {
    public var write: PendingWrite
    public var status: Int
    /// The server's `error` string, or the raw body when it sent none.
    public var message: String

    public init(write: PendingWrite, status: Int, message: String) {
        self.write = write
        self.status = status
        self.message = message
    }
}

/// Pushes queued local writes to the server and pulls its changes into the `AppDatabase`.
/// Being an actor, overlapping `sync()` calls run one after the other.
public actor SyncClient {
    let database: AppDatabase
    let api: ServerAPI

    /// Writes the server refused with a 4xx during the most recent push; the UI can show them.
    public private(set) var lastRejectedWrites: [RejectedWrite] = []

    public init(database: AppDatabase, config: ServerConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.database = database
        api = ServerAPI(config: config, transport: transport)
    }

    /// Pushes queued writes, then pulls and applies the server's changes even when a push failed,
    /// so one stuck write does not hold back incoming events and placements. Throws the push
    /// failure after the pull, if there was one.
    /// - Returns: the number of writes the server accepted.
    @discardableResult
    public func sync() async throws -> Int {
        let (pushed, failure) = try await pushQueue()
        try await pull()
        if let failure {
            throw failure
        }
        return pushed
    }

    /// Pushes queued writes in `seq` order; see `pushQueue()`.
    /// - Returns: the number of writes the server accepted.
    public func push() async throws -> Int {
        let (pushed, failure) = try await pushQueue()
        if let failure {
            throw failure
        }
        return pushed
    }

    /// Pushes queued writes in `seq` order. A 401 throws. A 5xx, transport or decoding failure
    /// stops the loop and is returned, keeping that row and the rest: later writes may depend on
    /// it (a task in a category not yet created). Another 4xx resets the local row to the server's
    /// copy, drops the write into `lastRejectedWrites`, and continues.
    private func pushQueue() async throws -> (pushed: Int, failure: SyncError?) {
        lastRejectedWrites = []
        var pushed = 0
        for write in try database.pendingWrites() {
            do {
                let (data, response) = try await api.send(request(for: write))
                switch response.statusCode {
                case 200..<300:
                    try applyAccepted(write, data: data)
                    pushed += 1
                case 401:
                    throw SyncError.unauthorized
                case 400..<500:
                    try await reconcileRejected(write)
                    lastRejectedWrites.append(RejectedWrite(write: write, status: response.statusCode, message: api.errorMessage(data)))
                default:
                    throw SyncError.http(status: response.statusCode, body: api.bodyText(data))
                }
            } catch SyncError.unauthorized {
                throw SyncError.unauthorized
            } catch let error as SyncError {
                return (pushed, error)
            }
        }
        return (pushed, nil)
    }

    /// `GET /api/sync?since=<cursor>` and applies the response.
    public func pull() async throws {
        var queryItems: [URLQueryItem] = []
        if let cursor = try database.cursor() {
            queryItems.append(URLQueryItem(name: "since", value: cursor))
        }
        let request = api.makeRequest(method: "GET", path: "api/sync", queryItems: queryItems)
        let response: SyncResponse = try await api.perform(request)
        try database.apply(response)
    }

    /// `POST /api/schedule/run` and applies the resulting placements.
    public func runScheduler() async throws {
        let result: SchedulingResult = try await api.perform(api.makeRequest(method: "POST", path: "api/schedule/run"))
        try database.apply(result, computedAt: Date())
    }

    /// `POST /api/google/sync` (refresh calendars, then reschedule) and applies the resulting placements.
    public func triggerGoogleSync() async throws {
        let result: SchedulingResult = try await api.perform(api.makeRequest(method: "POST", path: "api/google/sync"))
        try database.apply(result, computedAt: Date())
    }

    // MARK: - Push helpers

    private func collection(for entity: PendingWrite.Entity) -> String {
        switch entity {
        case .task: "api/tasks"
        case .category: "api/categories"
        case .schedule: "api/schedules"
        }
    }

    private func request(for write: PendingWrite) -> URLRequest {
        let collection = collection(for: write.entity)
        switch write.op {
        case .put:
            return api.makeRequest(method: "PUT", path: collection, id: write.entityId, body: write.body)
        case .delete:
            return api.makeRequest(method: "DELETE", path: collection, id: write.entityId)
        }
    }

    private func applyAccepted(_ write: PendingWrite, data: Data) throws {
        let now = Date()
        switch (write.entity, write.op) {
        case (.task, .put):
            let response = try api.decode(TaskWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.task, scheduling: response.scheduling, computedAt: now)
        case (.category, .put):
            let response = try api.decode(CategoryWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.category, scheduling: response.scheduling, computedAt: now)
        case (.schedule, .put):
            let response = try api.decode(ScheduleWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.schedule, scheduling: response.scheduling, computedAt: now)
        case (_, .delete):
            let response = try api.decode(SchedulingResponse.self, from: data)
            try database.completePendingWrite(write, record: nil as TaskItem?, scheduling: response.scheduling, computedAt: now)
        }
    }

    /// After a 4xx, `GET`s the entity (the bare row, as `/api/sync` serializes it) and resets the local row to the server's copy: saved when
    /// live, removed when tombstoned or when the server says it never existed (404 with `{error}`).
    /// A 404 without that body (an older server lacking the route) leaves the row as it is. Throws,
    /// keeping the write queued, when the server cannot be asked.
    private func reconcileRejected(_ write: PendingWrite) async throws {
        let (data, response) = try await api.send(api.makeRequest(method: "GET", path: collection(for: write.entity), id: write.entityId))
        switch response.statusCode {
        case 200..<300:
            switch write.entity {
            case .task:
                let row = try api.decode(TaskItem.self, from: data)
                try database.resolveRejectedWrite(write, serverRow: row.deletedAt == nil ? row : nil)
            case .category:
                let row = try api.decode(TaskCategory.self, from: data)
                try database.resolveRejectedWrite(write, serverRow: row.deletedAt == nil ? row : nil)
            case .schedule:
                let row = try api.decode(Schedule.self, from: data)
                try database.resolveRejectedWrite(write, serverRow: row.deletedAt == nil ? row : nil)
            }
        case 404 where api.serverError(data) != nil:
            try database.resolveRejectedWrite(write, serverRow: nil as TaskItem?)
        case 404:
            if let seq = write.seq {
                try database.removePendingWrite(seq: seq)
            }
        case 401:
            throw SyncError.unauthorized
        default:
            throw SyncError.http(status: response.statusCode, body: api.bodyText(data))
        }
    }
}
