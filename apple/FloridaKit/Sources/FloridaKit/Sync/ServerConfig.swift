import Foundation

/// Where the sync server is and the bearer token every `/api/*` request carries.
public struct ServerConfig: Hashable, Sendable, Codable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL = Florida.defaultServerURL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}
