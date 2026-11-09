import FloridaKit
import Foundation

/// A task block finished today, kept on the agenda as a struck-through ghost after the
/// scheduler has dropped its placement.
struct GhostBlock: Codable, Hashable, Identifiable {
    /// The placement's id, so a ghost and its still-live placement are drawn once.
    var id: String
    var taskId: String
    var title: String
    var categoryId: String
    var start: Date
    var end: Date
}

/// Today's ghosts in the app's own defaults (they are a display nicety, not synced data). Ghosts
/// of an earlier day are dropped on load.
enum GhostStore {
    private static let key = "ghostBlocks"

    private struct Stored: Codable {
        var day: Date
        var ghosts: [GhostBlock]
    }

    static func load(today: Date, calendar: Calendar) -> [GhostBlock] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              calendar.isDate(stored.day, inSameDayAs: today)
        else { return [] }
        return stored.ghosts
    }

    static func save(_ ghosts: [GhostBlock], today: Date) {
        guard let data = try? JSONEncoder().encode(Stored(day: today, ghosts: ghosts)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
