import Foundation

public struct LaterItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case article, video, other
    }

    public enum Source: String, Codable, Sendable {
        case share, mcp, manual
    }

    public enum Status: String, Codable, Sendable {
        case queue, read, archived
    }

    public enum Action: String, Codable, Sendable {
        case read, later, archive
    }

    public var id: String
    public var url: String
    public var canonicalUrl: String
    public var title: String
    public var site: String
    public var kind: Kind
    public var estMinutes: Int?
    public var enrichedAt: Date?
    public var savedAt: Date
    public var readAt: Date?
    public var archivedAt: Date?
    public var source: Source
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String, url: String, canonicalUrl: String, title: String, site: String, kind: Kind,
        estMinutes: Int? = nil, savedAt: Date, readAt: Date? = nil, archivedAt: Date? = nil,
        source: Source, updatedAt: Date, deletedAt: Date? = nil, enrichedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.canonicalUrl = canonicalUrl
        self.title = title
        self.site = site
        self.kind = kind
        self.estMinutes = estMinutes
        self.enrichedAt = enrichedAt
        self.savedAt = savedAt
        self.readAt = readAt
        self.archivedAt = archivedAt
        self.source = source
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var status: Status {
        archivedAt != nil ? .archived : readAt != nil ? .read : .queue
    }

    public var openURL: URL? { Self.webURL(url) }

    public static func webURL(_ string: String) -> URL? {
        guard let url = TaskSource.safeURL(string),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    public mutating func apply(_ action: Action, at now: Date) {
        readAt = action == .read ? now : nil
        archivedAt = action == .archive ? now : nil
        updatedAt = now
    }
}
