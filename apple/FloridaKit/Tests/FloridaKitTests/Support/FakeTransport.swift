import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FloridaKit

struct RecordedRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data?
}

enum ScriptedResponse {
    case json(status: Int, body: Data)
    case failure(any Error)

    /// 200 with `value` encoded the way the server encodes it.
    static func ok(_ value: some Encodable) throws -> ScriptedResponse {
        .json(status: 200, body: try JSONCoding.encoder.encode(value))
    }

    /// 200 with a prebuilt body.
    static func ok(_ body: Data) -> ScriptedResponse {
        .json(status: 200, body: body)
    }

    /// The server's `{error}` JSON with the given status.
    static func error(_ status: Int, _ message: String) -> ScriptedResponse {
        .json(status: status, body: Data("{\"error\":\"\(message)\"}".utf8))
    }
}

struct NoScriptedResponse: Error {}
struct NetworkDown: Error {}

/// Records every request and answers them with scripted responses in order.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [ScriptedResponse]
    private var recorded: [RecordedRequest] = []

    init(_ responses: [ScriptedResponse]) {
        self.responses = responses
    }

    var requests: [RecordedRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let next: ScriptedResponse = try lock.withLock {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let query = (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            recorded.append(RecordedRequest(
                method: request.httpMethod ?? "GET",
                path: url.path,
                query: Dictionary(query, uniquingKeysWith: { first, _ in first }),
                headers: request.allHTTPHeaderFields ?? [:],
                body: request.httpBody))
            guard !responses.isEmpty else { throw NoScriptedResponse() }
            return responses.removeFirst()
        }
        switch next {
        case .json(let status, let body):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (body, response)
        case .failure(let error):
            throw error
        }
    }
}
