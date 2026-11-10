import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Calls the server's AI endpoints. Nothing here touches the store: the caller shows the result
/// for review and saves what the user accepts through `AppDatabase`, so a slow or failed answer
/// never blocks the local write path. Errors are `SyncError`s; a server without AI configured
/// answers `.http(status: 503, …)`.
public actor AIClient {
    private let api: ServerAPI

    public init(config: ServerConfig, transport: any HTTPTransport = URLSessionTransport()) {
        api = ServerAPI(config: config, transport: transport)
    }

    /// `POST /api/ai/parse-task`: reads one line of text as a task, resolving dates in `timeZone`
    /// as of now.
    public func parseTask(_ text: String, timeZone: TimeZone = .autoupdatingCurrent) async throws -> TaskDraft {
        let body = try JSONCoding.encoder.encode(ParseTaskBody(text: text, now: Date(), timeZone: timeZone.identifier))
        let response: ParseTaskResponse = try await api.perform(
            api.makeRequest(method: "POST", path: "api/ai/parse-task", body: body))
        return response.draft
    }

    /// `POST /api/ai/suggest-category`: picks the live category a task most likely belongs to.
    public func suggestCategory(title: String, notes: String?) async throws -> CategorySuggestion {
        let body = try JSONCoding.encoder.encode(SuggestCategoryBody(title: title, notes: notes))
        return try await api.perform(api.makeRequest(method: "POST", path: "api/ai/suggest-category", body: body))
    }

    /// `POST /api/ai/brief`: has the server write today's brief or this week's review now, from the
    /// current plan. The server stores it; save the result with `AppDatabase.storeBrief` to show it
    /// before the next sync.
    public func writeBrief(_ kind: BriefKind) async throws -> Brief {
        let body = try JSONCoding.encoder.encode(BriefBody(kind: kind))
        let response: BriefResponse = try await api.perform(api.makeRequest(method: "POST", path: "api/ai/brief", body: body))
        return response.brief
    }

    /// `POST /api/ai/explain`: why the task is planned where it is, or why it is not planned.
    public func explainPlacement(taskId: String) async throws -> String {
        let body = try JSONCoding.encoder.encode(ExplainBody(taskId: taskId))
        let response: ExplainResponse = try await api.perform(
            api.makeRequest(method: "POST", path: "api/ai/explain", body: body))
        return response.explanation
    }
}

struct BriefBody: Codable {
    var kind: BriefKind
}

struct BriefResponse: Codable {
    var brief: Brief
}

struct ExplainBody: Codable {
    var taskId: String
}

struct ExplainResponse: Codable {
    var explanation: String
}

struct ParseTaskBody: Codable {
    var text: String
    var now: Date
    var timeZone: String
}

struct ParseTaskResponse: Codable {
    var draft: TaskDraft
}

struct SuggestCategoryBody: Codable {
    var title: String
    var notes: String?
}
