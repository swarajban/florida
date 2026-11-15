import Foundation

public enum AllDayPresentation {
    public struct Item: Identifiable, Hashable, Sendable {
        public let events: [CalendarEvent]
        public let title: String
        public var id: String { events[0].id }
        public var isGroup: Bool { events.count > 1 }
    }

    public static func items(
        for events: [CalendarEvent], calendarName: (String) -> String? = { _ in nil }
    ) -> [Item] {
        let coworkers = events.filter { isCoworkerOOO($0, calendarName: calendarName($0.calendarId)) }
        var emitted = false
        return events.compactMap { event in
            guard coworkers.contains(where: { $0.id == event.id }) else {
                return Item(events: [event], title: event.summary ?? "Untitled event")
            }
            guard !emitted else { return nil }
            emitted = true
            let names = coworkers.map { shortName(from: $0.summary ?? "") }
            let extra = names.count > 2 ? " +\(names.count - 2)" : ""
            return Item(events: coworkers, title: "OOO: \(names.prefix(2).joined(separator: ", "))\(extra)")
        }
    }

    public static func isCoworkerOOO(_ event: CalendarEvent, calendarName: String?) -> Bool {
        guard event.allDay, event.isVisible,
              !(event.blocksDay ?? event.autoBlocksDay ?? event.isOutOfOffice) else { return false }
        let reason = event.blockingReason?.lowercased() ?? ""
        guard !reason.hasPrefix("your ") else { return false }
        let gusto = calendarName?.range(of: #"^gusto\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let coworkerReason = reason == "someone else’s time off" || reason == "someone else's time off"
        return timeOffRange(in: event.summary ?? "") != nil && (gusto || coworkerReason)
    }

    public static func shortName(from title: String) -> String {
        guard let range = timeOffRange(in: title) else { return "Someone" }
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—:()"))
        let before = String(title[..<range.lowerBound])
            .replacingOccurrences(of: #"^pending\s+|\b(?:(?:is|on|will be)\s*)+$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: trim)
        let after = String(title[range.upperBound...]).trimmingCharacters(in: trim)
        let name = before.isEmpty ? after : before
        guard let first = name.split(whereSeparator: { $0.isWhitespace }).first,
              !["my", "the", "team"].contains(first.lowercased()) else { return "Someone" }
        return String(first)
    }

    private static func timeOffRange(in title: String) -> Range<String.Index>? {
        title.range(of: #"\b(?:ooo|out[ -]of[ -]office|time[ -]off|pto|vacation|annual leave|sick leave)\b"#,
                    options: [.regularExpression, .caseInsensitive])
    }
}
