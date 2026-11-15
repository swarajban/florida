import Foundation

public struct GuestSuggestion: Hashable, Sendable {
    public var email: String
    public var displayName: String?

    public init(email: String, displayName: String? = nil) {
        self.email = email
        self.displayName = displayName
    }

    public static func isEmail(_ value: String) -> Bool {
        value.range(of: #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+$"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func ranked(
        query: String, calendars: [CalendarInfo], accounts: [GoogleAccount],
        attendees: [EventAttendee], limit: Int = 10
    ) -> [GuestSuggestion] {
        let own = Set(accounts.map { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var candidates: [String: (suggestion: GuestSuggestion, frequency: Int)] = [:]
        func add(_ email: String, _ name: String?) {
            let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard isEmail(email), !email.hasSuffix(".calendar.google.com"), !own.contains(email) else { return }
            let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            var value = candidates[email] ?? (GuestSuggestion(email: email), 0)
            if let name, !name.isEmpty { value.suggestion.displayName = name }
            value.frequency += 1
            candidates[email] = value
        }
        for calendar in calendars { add(calendar.googleId, calendar.summary) }
        for attendee in attendees where !attendee.isSelf { add(attendee.email, attendee.displayName) }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func score(_ suggestion: GuestSuggestion) -> Int {
            guard !needle.isEmpty else { return 0 }
            let values = [suggestion.email, suggestion.displayName?.lowercased() ?? ""]
            if values.contains(needle) { return 3 }
            if values.contains(where: { $0.hasPrefix(needle) }) { return 2 }
            return values.contains(where: { $0.contains(needle) }) ? 1 : -1
        }
        return candidates.values.filter { score($0.suggestion) >= 0 }.sorted {
            let lhs = score($0.suggestion), rhs = score($1.suggestion)
            if lhs != rhs { return lhs > rhs }
            if $0.frequency != $1.frequency { return $0.frequency > $1.frequency }
            return $0.suggestion.email < $1.suggestion.email
        }.prefix(max(0, limit)).map(\.suggestion)
    }
}

extension EventAttendeeWrite {
    public static func normalized(_ attendees: [EventAttendeeWrite]) -> [EventAttendeeWrite] {
        var seen = Set<String>()
        return attendees.compactMap {
            var attendee = $0
            attendee.email = attendee.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let name = attendee.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) {
                attendee.displayName = name.isEmpty ? nil : name
            }
            guard seen.insert(attendee.email).inserted else { return nil }
            return attendee
        }
    }

    public static func merging(_ attendees: [EventAttendeeWrite], into existing: [EventAttendee]) -> [EventAttendee] {
        let attendees = normalized(attendees)
        var requested = Dictionary(uniqueKeysWithValues: attendees.map { ($0.email, $0) })
        var result = existing.compactMap { old -> EventAttendee? in
            let desired = requested.removeValue(forKey: old.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            guard desired != nil || old.isSelf || old.organizer else { return nil }
            var attendee = old
            if let desired {
                if let name = desired.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    attendee.displayName = name
                }
                attendee.optional = desired.optional
            }
            return attendee
        }
        for desired in attendees where requested[desired.email] != nil {
            result.append(EventAttendee(email: desired.email, displayName: desired.displayName, optional: desired.optional))
        }
        return result
    }
}
