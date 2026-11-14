import Foundation

extension CalendarInfo {
    /// New-event choices: Sempre, Personal, A&S Family Calendar, then the other calendars.
    /// Callers restrict new-event choices to selected writable calendars.
    public static func isPreferredForNewEvents(_ lhs: CalendarInfo, _ rhs: CalendarInfo, accounts: [GoogleAccount]) -> Bool {
        (lhs.eventRank(accounts: accounts), lhs.selected ? 0 : 1, lhs.summary.lowercased(), lhs.id)
            < (rhs.eventRank(accounts: accounts), rhs.selected ? 0 : 1, rhs.summary.lowercased(), rhs.id)
    }

    private func eventRank(accounts: [GoogleAccount]) -> Int {
        // Google's primary calendar ID is the account email even if its display name changes.
        // Match a connected identity, not every shared calendar at the same company.
        if let account = accounts.first(where: { $0.email.caseInsensitiveCompare(googleId) == .orderedSame }) {
            let domain = account.email.lowercased().split(separator: "@").last
            if domain == "sempre-health.com" || domain == "semprehealth.com" { return 0 }
            if account.label.lowercased() == "personal" || domain == "gmail.com" { return 1 }
        }
        switch summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sempre": return 0
        case "personal": return 1
        case "a&s family calendar": return 2
        default: return 3
        }
    }
}
