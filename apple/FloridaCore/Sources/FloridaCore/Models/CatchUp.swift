import Foundation

public struct CatchUpSettings: Codable, Hashable, Sendable {
    public struct Window: Codable, Hashable, Sendable {
        public var days: [Int]
        public var start: String
        public var end: String
        public var minutes: Int?

        public init(days: [Int], start: String, end: String, minutes: Int? = nil) {
            self.days = days
            self.start = start
            self.end = end
            self.minutes = minutes
        }
    }

    public var enabled: Bool
    public var minutes: Int
    public var windows: [Window]

    public init(enabled: Bool, minutes: Int, windows: [Window]) {
        self.enabled = enabled
        self.minutes = minutes
        self.windows = windows
    }
}

public struct CatchUpBlock: Codable, Hashable, Identifiable, Sendable {
    public struct Item: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var site: String
        public var url: String
        public var estMinutes: Int

        public init(id: String, title: String, site: String, url: String, estMinutes: Int) {
            self.id = id
            self.title = title
            self.site = site
            self.url = url
            self.estMinutes = estMinutes
        }
    }

    public var id: String
    public var startAt: Date
    public var endAt: Date
    public var items: [Item]

    public init(id: String, startAt: Date, endAt: Date, items: [Item]) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.items = items
    }
}
