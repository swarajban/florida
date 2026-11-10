import Foundation

// The one order categories are listed in, everywhere they are listed or picked: Inbox, then the
// work categories, then the personal ones, then any without an area; by name within each, ignoring
// case. `sortOrder` plays no part: the order follows from what a category is, not from where it
// was last dragged.

extension TaskCategory {
    /// Whether `lhs` is listed before `rhs`. Names that differ only in case fall back to the id,
    /// so the order is the same on every device.
    public static func isListedBefore(_ lhs: TaskCategory, _ rhs: TaskCategory) -> Bool {
        (lhs.listRank, lhs.name.lowercased(), lhs.id) < (rhs.listRank, rhs.name.lowercased(), rhs.id)
    }

    private var listRank: Int {
        if isInbox { return 0 }
        switch area {
        case .work: return 1
        case .personal: return 2
        case nil: return 3
        }
    }
}

extension Sequence where Element == TaskCategory {
    /// The categories in the order they are listed: see `TaskCategory.isListedBefore`.
    public func inListOrder() -> [TaskCategory] {
        sorted(by: TaskCategory.isListedBefore)
    }
}
