import Foundation

extension CalendarInfo {
    /// New-event choices: Sempre, Personal, A&S Family Calendar, then the other calendars.
    /// Visibility only breaks ties: hiding Sempre's events must not change the default.
    public static func isPreferredForNewEvents(_ lhs: CalendarInfo, _ rhs: CalendarInfo) -> Bool {
        (lhs.eventRank, lhs.selected ? 0 : 1, lhs.summary.lowercased(), lhs.id)
            < (rhs.eventRank, rhs.selected ? 0 : 1, rhs.summary.lowercased(), rhs.id)
    }

    private var eventRank: Int {
        switch summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sempre": 0
        case "personal": 1
        case "a&s family calendar": 2
        default: 3
        }
    }
}
