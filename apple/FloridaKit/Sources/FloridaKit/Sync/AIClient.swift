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
