import Foundation

/// What the focus ring is on: one task (every placement of it lights up) or one Google event.
enum ItemID: Hashable, Sendable {
    case task(String)
    case event(String)

    var isTask: Bool {
        if case .task = self { return true }
        return false
    }
}

/// Which pane `j` / `k` move through.
enum Panel: Hashable, Sendable {
    case calendar
    case tasks
}
