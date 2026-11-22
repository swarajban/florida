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
/// never succeed, and the local row has been reset to the server's copy: saved when the server has
/// it live, removed when tombstoned. A rejected `put` of a row the server never had keeps the local
/// row, so the user's edit stays visible; `write.body` holds what was sent.
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
    private let diagnostics: DiagnosticsRecorder
    private var syncInProgress = false
    private var syncWaiters: [CheckedContinuation<Void, Never>] = []

    /// Writes the server refused with a 4xx during the most recent push; the UI can show them.
    public private(set) var lastRejectedWrites: [RejectedWrite] = []

    public init(
        database: AppDatabase, config: ServerConfig, transport: any HTTPTransport = URLSessionTransport(),
        diagnostics: DiagnosticsRecorder = .shared
    ) {
        self.database = database
        api = ServerAPI(config: config, transport: transport)
        self.diagnostics = diagnostics
    }

    /// Pushes queued writes, then pulls and applies the server's changes even when a push failed,
    /// so one stuck write does not hold back incoming events and placements. Throws the push
    /// failure after the pull, if there was one.
    /// - Returns: the number of writes the server accepted.
    @discardableResult
    public func sync() async throws -> Int {
        await acquireSync()
        defer { releaseSync() }
        let (pushed, failure) = try await pushQueue()
        try await pullChanges()
        if let failure {
            throw failure
        }
        return pushed
    }

    /// Pushes queued writes; see `pushQueue()`.
    /// - Returns: the number of writes the server accepted.
    public func push() async throws -> Int {
        await acquireSync()
        defer { releaseSync() }
        let (pushed, failure) = try await pushQueue()
        if let failure {
            throw failure
        }
        return pushed
    }

    private func acquireSync() async {
        if syncInProgress {
            await withCheckedContinuation { syncWaiters.append($0) }
        } else {
            syncInProgress = true
        }
    }

    private func releaseSync() {
        if syncWaiters.isEmpty {
            syncInProgress = false
        } else {
            syncWaiters.removeFirst().resume()
        }
    }

    /// Pushes queued writes, the rows other rows name first (`PendingWrite.pushRank`) and in `seq`
    /// order otherwise. A 401 throws. Any other failure (5xx, transport, decoding, or the local
    /// store) stops the loop and is returned, keeping that row and the rest: later writes may
    /// depend on it (a task in a category not yet created). A 404 that is not the server's own (no
    /// `{error}` body) means the server predates the route: the write stays queued for a newer
    /// server and the loop goes on. A task filed under a project that stayed queued this way waits
    /// with it, unsent: that server would accept the task and drop its project. Another 4xx resets
    /// the local row to the server's copy, drops the write into `lastRejectedWrites`, and continues.
    private func pushQueue() async throws -> (pushed: Int, failure: (any Error)?) {
        lastRejectedWrites = []
        do {
            try await recoverCategoryDeletions()
        } catch SyncError.unauthorized {
            diagnostics.error("write", "recovery-error", SyncError.unauthorized)
            throw SyncError.unauthorized
        } catch {
            diagnostics.error("write", "recovery-error", error)
            return (0, error)
        }
        var pushed = 0
        var projectsLeftQueued: Set<String> = []
        let queue: [PendingWrite]
        do {
            queue = try database.pendingWrites().sorted { ($0.pushRank, $0.seq ?? .max) < ($1.pushRank, $1.seq ?? .max) }
        } catch {
            diagnostics.error("write", "queue-error", error)
            throw error
        }
        for entry in queue {
            do {
                if entry.entity == .task || entry.entity == .project {
                    try await recoverCategoryDeletions()
                    if try database.hasPendingCategoryWrites() {
                        continue
                    }
                }
                guard let seq = entry.seq, let write = try database.pendingWrite(seq: seq) else { continue }
                if let project = write.namedProjectId, projectsLeftQueued.contains(project) {
                    continue
                }
                let deletedCreation = write.op == .delete ? try database.deletedQueuedCreation(write) : false
                let request = request(for: write)
                let (data, response) = try await sendWrite(write, request)
                switch response.statusCode {
                case 200..<300:
                    try applyAccepted(write, data: data)
                    diagnostics.record("write", "accepted", write.diagnosticFields)
                    diagnostics.record("scheduler", "write-placement-refresh", write.diagnosticFields)
                    pushed += 1
                case 401:
                    throw SyncError.unauthorized
                case 404 where api.serverError(data) == nil:
                    diagnostics.record("write", "retry-pending", write.diagnosticFields.merging(["status": .value("404")]) { _, new in new })
                    if write.entity == .project {
                        projectsLeftQueued.insert(write.entityId)
                    }
                    continue
                case 404 where deletedCreation:
                    try database.resolveDroppedWrite(write, serverCopy: .missing)
                    diagnostics.record("write", "already-deleted", write.diagnosticFields)
                    pushed += 1
                case 400..<500:
                    diagnostics.record("write", "rejected", write.diagnosticFields.merging(["status": .value(String(response.statusCode))]) { _, new in new })
                    try database.resolveDroppedWrite(write, serverCopy: try await fetchServerCopy(of: write))
                    lastRejectedWrites.append(RejectedWrite(write: write, status: response.statusCode, message: api.errorMessage(data)))
                default:
                    throw SyncError.http(status: response.statusCode, body: api.errorMessage(data))
                }
            } catch SyncError.unauthorized {
                diagnostics.error("write", "blocked", SyncError.unauthorized)
                throw SyncError.unauthorized
            } catch {
                diagnostics.record("write", "retry-pending", entry.diagnosticFields)
                diagnostics.error("write", "push-error", error)
                return (pushed, error)
            }
        }
        return (pushed, nil)
    }

    private func recoverCategoryDeletions() async throws {
        for id in try database.categoryDeletionsNeedingRecovery() {
            let write = PendingWrite(entity: .category, entityId: id, op: .delete, body: nil, createdAt: Date())
            let copy = try await fetchServerCopy(of: write)
            if case .unavailable = copy {
                throw SyncError.http(status: 404, body: "Category \(id) must be reconciled before sending dependent changes")
            }
            try database.resolveDroppedWrite(write, serverCopy: copy)
        }
    }

    /// Drops `write` from the queue without pushing it, then resets the local row to the server's
    /// copy so the two stop diverging: saved when the server has it live, removed when tombstoned,
    /// left as it is when the server does not know it. Throws when the server cannot be asked; the
    /// write is gone either way.
    public func discard(_ write: PendingWrite) async throws {
        await acquireSync()
        defer { releaseSync() }
        if let seq = write.seq {
            try database.removePendingWrite(seq: seq)
        }
        try database.resolveDroppedWrite(write, serverCopy: try await fetchServerCopy(of: write))
        diagnostics.record("write", "discarded", write.diagnosticFields)
    }

    /// `GET /api/sync?since=<cursor>` and applies the response.
    public func pull() async throws {
        await acquireSync()
        defer { releaseSync() }
        try await pullChanges()
    }

    private func pullChanges() async throws {
        do {
            let cursor = try database.cursor()
            diagnostics.record("sync", "pull-start", ["cursor": .value(Self.diagnosticCursor(cursor))])
            let queryItems = cursor.map { [URLQueryItem(name: "since", value: $0)] } ?? []
            let request = api.makeRequest(method: "GET", path: "api/sync", queryItems: queryItems)
            let response: SyncResponse = try await api.perform(request)
            try database.apply(response)
            diagnostics.record("sync", "pull-end", [
                "cursor": .value(Self.diagnosticCursor(response.cursor)),
                "tasks": .value(String(response.tasks.count)), "events": .value(String(response.events.count)),
                "categories": .value(String(response.categories.count)), "schedules": .value(String(response.schedules.count)),
                "projects": .value(String(response.projects.count)), "accounts": .value(String(response.accounts.count)),
                "calendars": .value(String(response.calendars.count)), "overrides": .value(String(response.dayOverrides.count)),
                "placements": .value(String(response.placements.count)), "unscheduled": .value(String(response.unscheduled.count)),
            ])
        } catch {
            diagnostics.error("sync", "pull-error", error)
            throw error
        }
    }

    private static func diagnosticCursor(_ cursor: String?) -> String {
        guard let cursor else { return "-" }
        guard cursor.utf8.count <= 32,
              cursor.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#, options: .regularExpression) != nil else {
            return "invalid"
        }
        return cursor
    }

    /// `POST /api/schedule/run` and applies the resulting placements.
    public func runScheduler() async throws {
        try await refreshPlacements("scheduler", path: "api/schedule/run")
    }

    /// `POST /api/google/sync` (refresh calendars, then reschedule) and applies the resulting placements.
    public func triggerGoogleSync() async throws {
        try await refreshPlacements("calendar", path: "api/google/sync")
    }

    private func refreshPlacements(_ subsystem: String, path: String) async throws {
        diagnostics.record(subsystem, "refresh-start")
        do {
            let result: SchedulingResult = try await api.perform(api.makeRequest(method: "POST", path: path))
            try database.apply(result, computedAt: Date())
            diagnostics.record(subsystem, "refresh-end", [
                "placements": .value(String(result.placements.count)),
                "unscheduled": .value(String(result.unscheduled.count)),
            ])
        } catch {
            diagnostics.error(subsystem, "refresh-error", error)
            throw error
        }
    }

    // MARK: - Push helpers

    private func collection(for entity: PendingWrite.Entity) -> String {
        switch entity {
        case .task: "api/tasks"
        case .category: "api/categories"
        case .schedule: "api/schedules"
        case .event: "api/events"
        case .project: "api/projects"
        case .dayOverride: "api/day-overrides"
        case .calendar: "api/calendars"
        }
    }

    private func request(for write: PendingWrite) -> URLRequest {
        let collection = collection(for: write.entity)
        switch write.op {
        case .put:
            return api.makeRequest(method: "PUT", path: collection, id: write.entityId, body: write.body)
        case .patch:
            return api.makeRequest(method: "PATCH", path: collection, id: write.entityId, body: write.body)
        case .delete:
            return api.makeRequest(method: "DELETE", path: collection, id: write.entityId)
        }
    }

    private func sendWrite(_ write: PendingWrite, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard diagnostics.isRecording else { return try await api.send(request) }
        var fields = write.diagnosticFields
        fields["method"] = .value(write.op.rawValue.uppercased())
        fields["path"] = .value("/\(collection(for: write.entity))/:id")
        if write.entity == .task || write.entity == .event,
           let body = request.httpBody,
           let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let title = object[write.entity == .task ? "title" : "summary"] as? String {
            fields["title"] = titleField(title)
        }
        diagnostics.record("http", "write-send", fields)
        fields["title"] = nil
        let sent = ContinuousClock.now
        do {
            let result = try await api.send(request)
            fields["status"] = .value(String(result.1.statusCode))
            fields["ms"] = .value(Self.elapsedMilliseconds(since: sent))
            diagnostics.record("http", "write-end", fields)
            return result
        } catch {
            fields["status"] = .value("no-response")
            fields["ms"] = .value(Self.elapsedMilliseconds(since: sent))
            diagnostics.record("http", "write-end", fields)
            throw error
        }
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: .now).components
        return String(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    private func titleField(_ title: String) -> DiagnosticsRecorder.Field {
        let token = api.config.token
        return token.isEmpty || !title.contains(token) ? .text(title) : .value("[credential omitted]")
    }

    private func applyAccepted(_ write: PendingWrite, data: Data) throws {
        let now = Date()
        switch (write.entity, write.op) {
        case (.task, .put), (.task, .patch):
            let response = try api.decode(TaskWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.task, scheduling: response.scheduling, computedAt: now)
            diagnostics.record("write", "accepted-title", write.diagnosticFields.merging(["title": titleField(response.task.title)]) { _, new in new })
        case (.category, .put), (.category, .patch):
            let response = try api.decode(CategoryWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.category, scheduling: response.scheduling, computedAt: now)
        case (.schedule, .put), (.schedule, .patch):
            let response = try api.decode(ScheduleWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.schedule, scheduling: response.scheduling, computedAt: now)
        case (.event, .put), (.event, .patch):
            let response = try api.decode(EventWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.event, scheduling: response.scheduling, computedAt: now)
            if let summary = response.event.summary {
                diagnostics.record("write", "accepted-title", write.diagnosticFields.merging(["title": titleField(summary)]) { _, new in new })
            }
        case (.project, .put), (.project, .patch):
            let response = try api.decode(ProjectWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.project, scheduling: response.scheduling, computedAt: now)
        case (.dayOverride, .put), (.dayOverride, .patch):
            let response = try api.decode(DayOverrideWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.dayOverride, scheduling: response.scheduling, computedAt: now)
        case (.calendar, .put), (.calendar, .patch):
            let response = try api.decode(SchedulingResponse.self, from: data)
            try database.completePendingWrite(write, record: nil as CalendarInfo?, scheduling: response.scheduling, computedAt: now)
        case (_, .delete):
            let response = try api.decode(SchedulingResponse.self, from: data)
            try database.completePendingWrite(write, record: nil as TaskItem?, scheduling: response.scheduling, computedAt: now)
        }
    }

    /// `GET`s the entity `write` targets (the bare row, as `/api/sync` serializes it). A 404 with the
    /// server's `{error}` body means the server never had it; one without that body comes from an
    /// older server lacking the route. Throws when the server cannot be asked (401, 5xx, transport
    /// or decoding failure), so a caller pushing the write keeps it queued.
    private func fetchServerCopy(of write: PendingWrite) async throws -> AppDatabase.ServerCopy {
        if write.entity == .calendar {
            let response: SyncResponse = try await api.perform(api.makeRequest(method: "GET", path: "api/sync"))
            return response.calendars.first(where: { $0.id == write.entityId }).map { .live($0) } ?? .missing
        }
        let request = api.makeRequest(method: "GET", path: collection(for: write.entity), id: write.entityId)
        let (data, response) = try await api.send(request)
        switch response.statusCode {
        case 200..<300:
            switch write.entity {
            case .task:
                let row = try api.decode(TaskItem.self, from: data)
                return row.deletedAt == nil ? .live(row) : .tombstoned
            case .category:
                let row = try api.decode(TaskCategory.self, from: data)
                return row.deletedAt == nil ? .live(row) : .tombstoned
            case .schedule:
                let row = try api.decode(Schedule.self, from: data)
                return row.deletedAt == nil ? .live(row) : .tombstoned
            case .event:
                let row = try api.decode(CalendarEvent.self, from: data)
                return row.deletedAt == nil ? .live(row) : .tombstoned
            case .project:
                let row = try api.decode(Project.self, from: data)
                return row.deletedAt == nil ? .live(row) : .tombstoned
            case .dayOverride:
                let row = try api.decode(DayOverride.self, from: data)
                return row.deletedAt == nil ? .live(row) : .tombstoned
            case .calendar:
                return .live(try api.decode(CalendarInfo.self, from: data))
            }
        case 404 where api.serverError(data) != nil:
            return .missing
        case 404:
            return .unavailable
        case 401:
            throw SyncError.unauthorized
        default:
            throw SyncError.http(status: response.statusCode, body: api.errorMessage(data))
        }
    }
}
