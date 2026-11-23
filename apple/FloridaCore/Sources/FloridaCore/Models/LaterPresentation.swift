import Foundation

public struct LaterPresentation {
    public let queue: [LaterItem]
    public let read: [LaterItem]
    public let archived: [LaterItem]

    public init(items: [LaterItem]) {
        let groups = Dictionary(grouping: items.filter { $0.deletedAt == nil }, by: \.status)
        queue = groups[.queue, default: []]
        read = groups[.read, default: []]
        archived = groups[.archived, default: []]
    }

    public func items(in status: LaterItem.Status) -> [LaterItem] {
        switch status {
        case .queue: queue
        case .read: read
        case .archived: archived
        }
    }

    public func archivedThisMonth(at now: Date, calendar: Calendar) -> String {
        let count = archived.count { item in
            item.archivedAt.map { calendar.isDate($0, equalTo: now, toGranularity: .month) } ?? false
        }
        return "\(count) archived this month"
    }

    public func items(in block: CatchUpBlock) -> [LaterItem] {
        let unread = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0) })
        return block.items.compactMap { scheduled in
            guard var item = unread[scheduled.id] else { return nil }
            item.estMinutes = item.estMinutes ?? scheduled.estMinutes
            return item
        }
    }
}

extension LaterItem.Status {
    public var laterDisplayTitle: String { rawValue.capitalized }
}

extension LaterItem {
    public var laterEstimateLabel: String { estMinutes.map { "\($0) min" } ?? "No estimate yet" }
}

extension CatchUpBlock {
    public var laterDisplayTitle: String { "Catch up · \(items.count)" }
}

public struct LaterVisit {
    private var openedUnreadID: String?

    public init() {}

    public mutating func open(_ item: LaterItem) {
        openedUnreadID = item.status == .queue ? item.id : nil
    }

    public mutating func finish(in later: LaterPresentation) -> LaterItem? {
        defer { openedUnreadID = nil }
        return later.queue.first { $0.id == openedUnreadID }
    }
}
