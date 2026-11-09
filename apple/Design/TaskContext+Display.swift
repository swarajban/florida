import FloridaKit
import Foundation

extension TaskContext {
    var displayName: String {
        switch self {
        case .computer: "Computer"
        case .errand: "Errand"
        case .home: "Home"
        case .office: "Office"
        }
    }

    /// SF Symbol for pickers and quick-add chips.
    var symbolName: String {
        switch self {
        case .computer: "laptopcomputer"
        case .errand: "figure.walk"
        case .home: "house"
        case .office: "building.2"
        }
    }
}

extension CategoryArea {
    var displayName: String {
        switch self {
        case .work: "Work"
        case .personal: "Personal"
        }
    }

    /// What the category editors say under the Work / Personal choice.
    static let footnote = "Evening suggestions put personal categories first."
}

/// The weekly routine in words, for the read-only routine screens of both apps.
enum RoutineText {
    /// "Mon, Thu, Fri 09:00–15:30": days Monday first, hours as stored (24-hour wall clock).
    static func when(_ block: RoutineBlock, calendar: Calendar) -> String {
        let names = calendar.shortWeekdaySymbols
        let days = [1, 2, 3, 4, 5, 6, 0].filter(block.days.contains).map { names[$0] }
        return "\(days.joined(separator: ", ")) \(block.start)–\(block.end)"
    }

    /// "Computer, Errand, Home"; a block that allows nothing says so.
    static func allows(_ block: RoutineBlock) -> String {
        block.allows.isEmpty ? "Nothing scheduled" : block.allows.map(\.displayName).joined(separator: ", ")
    }

    /// What the routine screens say about a block the plan never uses.
    static let optionalNote = "Optional: suggestions only, never planned on"

    /// Heading over one day's suggestions for an optional block: "Evening, if you're up for it".
    static func picksTitle(_ picks: OptionalPicks) -> String {
        "\(picks.blockName ?? "Later"), if you're up for it"
    }

    /// What the button that takes a suggestion says: "Do tonight" for one this evening, "Do today"
    /// earlier in the day, "Plan it" for another day. Taking pins the task at the suggested start.
    static func takeTitle(_ placement: OptionalPlacement, now: Date, calendar: Calendar) -> String {
        guard calendar.isDate(placement.startAt, inSameDayAs: now) else { return "Plan it" }
        return calendar.component(.hour, from: placement.startAt) >= 17 ? "Do tonight" : "Do today"
    }

    /// The rule the routine applies, with its time zone once the settings row has synced.
    static func footnote(timeZone: String?) -> String {
        let rule = "A task is placed only in a block that allows its context; "
            + "only a hard deadline that would otherwise be missed may spill outside. "
            + "An optional block is never planned on: it only gets suggestions you can take or ignore."
        return timeZone.map { "Hours are in \($0). \(rule)" } ?? rule
    }
}
