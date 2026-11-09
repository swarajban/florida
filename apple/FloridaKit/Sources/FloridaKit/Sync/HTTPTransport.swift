import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one HTTP request. `URLSessionTransport` is the real one; tests substitute a fake.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Builds authenticated requests to the Florida server and maps its responses to `SyncError`.
/// Shared by `SyncClient` and `AIClient`.
struct ServerAPI: Sendable {
    let config: ServerConfig
    let transport: any HTTPTransport

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

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
            throw SyncError.http(status: response.statusCode, body: errorMessage(data))
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONCoding.decoder.decode(type, from: data)
        } catch {
            throw SyncError.decoding(error)
        }
    }

    func bodyText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private struct ErrorBody: Decodable {
        var error: String
    }

    /// The `error` of the server's `{error}` JSON, if the body is one.
    func serverError(_ data: Data) -> String? {
        try? JSONDecoder().decode(ErrorBody.self, from: data).error
    }

    func errorMessage(_ data: Data) -> String {
        serverError(data) ?? bodyText(data)
    }
}
