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

/// Pushes queued local writes to the server and pulls its changes into the `AppDatabase`.
/// Being an actor, overlapping `sync()` calls run one after the other.
public actor SyncClient {
    let database: AppDatabase
    private let config: ServerConfig
    private let transport: any HTTPTransport

    /// Writes the server refused with a 4xx during the most recent `push()`. They have been dropped
    /// from the queue because retrying could never succeed; the UI can show them.
    public private(set) var lastRejectedWrites: [(write: PendingWrite, error: SyncError)] = []

    public init(database: AppDatabase, config: ServerConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.database = database
        self.config = config
        self.transport = transport
    }

    /// Pushes every queued write in order, then pulls and applies the server's changes.
    /// - Returns: the number of writes the server accepted.
    @discardableResult
    public func sync() async throws -> Int {
        let pushed = try await push()
        try await pull()
        return pushed
    }

    /// Pushes queued writes in `seq` order. A 401 or a 5xx/transport failure stops the loop and
    /// throws, keeping the remaining rows; another 4xx drops the write into `lastRejectedWrites`
    /// and continues.
    public func push() async throws -> Int {
        lastRejectedWrites = []
        var pushed = 0
        for write in try database.pendingWrites() {
            let (data, response) = try await send(request(for: write))
            switch response.statusCode {
            case 200..<300:
                try applyAccepted(write, data: data)
                pushed += 1
            case 401:
                throw SyncError.unauthorized
            case 400..<500:
                if let seq = write.seq {
                    try database.removePendingWrite(seq: seq)
                }
                lastRejectedWrites.append((write, .http(status: response.statusCode, body: bodyText(data))))
            default:
                throw SyncError.http(status: response.statusCode, body: bodyText(data))
            }
        }
        return pushed
    }

    /// `GET /api/sync?since=<cursor>` and applies the response.
    public func pull() async throws {
        var queryItems: [URLQueryItem] = []
        if let cursor = try database.cursor() {
            queryItems.append(URLQueryItem(name: "since", value: cursor))
        }
        let request = makeRequest(method: "GET", path: "api/sync", queryItems: queryItems)
        let response: SyncResponse = try await perform(request)
        try database.apply(response)
    }

    /// `POST /api/schedule/run` and applies the resulting placements.
    public func runScheduler() async throws {
        let result: SchedulingResult = try await perform(makeRequest(method: "POST", path: "api/schedule/run"))
        try database.apply(result, computedAt: Date())
    }

    /// `POST /api/google/sync` (refresh calendars, then reschedule) and applies the resulting placements.
    public func triggerGoogleSync() async throws {
        let result: SchedulingResult = try await perform(makeRequest(method: "POST", path: "api/google/sync"))
        try database.apply(result, computedAt: Date())
    }

    // MARK: - Push helpers

    private func request(for write: PendingWrite) -> URLRequest {
        let collection: String
        switch write.entity {
        case .task: collection = "api/tasks"
        case .project: collection = "api/projects"
        case .schedule: collection = "api/schedules"
        }
        switch write.op {
        case .put:
            return makeRequest(method: "PUT", path: collection, id: write.entityId, body: write.body)
        case .delete:
            return makeRequest(method: "DELETE", path: collection, id: write.entityId)
        }
    }

    private func applyAccepted(_ write: PendingWrite, data: Data) throws {
        let now = Date()
        switch (write.entity, write.op) {
        case (.task, .put):
            let response = try decode(TaskWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.task, scheduling: response.scheduling, computedAt: now)
        case (.project, .put):
            let response = try decode(ProjectWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.project, scheduling: response.scheduling, computedAt: now)
        case (.schedule, .put):
            let response = try decode(ScheduleWriteResponse.self, from: data)
            try database.completePendingWrite(write, record: response.schedule, scheduling: response.scheduling, computedAt: now)
        case (_, .delete):
            let response = try decode(SchedulingResponse.self, from: data)
            try database.completePendingWrite(write, record: nil as TaskItem?, scheduling: response.scheduling, computedAt: now)
        }
    }

    // MARK: - HTTP helpers

    func makeRequest(
        method: String, path: String, id: String? = nil, queryItems: [URLQueryItem] = [], body: Data? = nil
    ) -> URLRequest {
        var url = config.baseURL.appendingPathComponent(path)
        if let id {
            url.appendPathComponent(id)
        }
        if !queryItems.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw SyncError.transport(error)
        }
    }

    /// Sends the request and decodes a 2xx body; maps 401 and other statuses to `SyncError`.
    func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200..<300:
            return try decode(T.self, from: data)
        case 401:
            throw SyncError.unauthorized
        default:
            throw SyncError.http(status: response.statusCode, body: bodyText(data))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONCoding.decoder.decode(type, from: data)
        } catch {
            throw SyncError.decoding(error)
        }
    }

    private func bodyText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
