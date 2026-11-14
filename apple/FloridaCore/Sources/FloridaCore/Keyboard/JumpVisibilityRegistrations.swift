import Foundation

public struct JumpVisibilityRegistrations<Item: Hashable & Sendable>: Sendable {
    private var owners: [Item: Set<UUID>] = [:]

    public init() {}

    public var items: Set<Item> { Set(owners.keys) }

    public mutating func set(_ item: Item, owner: UUID, visible: Bool) {
        if visible {
            owners[item, default: []].insert(owner)
        } else {
            owners[item]?.remove(owner)
            if owners[item]?.isEmpty == true { owners.removeValue(forKey: item) }
        }
    }
}
