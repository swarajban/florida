import Foundation

public enum DateEntryResult: Equatable, Sendable {
    case date(Date, hasTime: Bool)
    case clear
    case invalid
}

public enum DateEntryQuickChoice: String, CaseIterable, Sendable {
    case today, tomorrow, weekend, nextWeek, none

    public var title: String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .weekend: "This weekend"
        case .nextWeek: "Next week"
        case .none: "No date"
        }
    }

    public var shortcut: String {
        switch self {
        case .today: "1"
        case .tomorrow: "2"
        case .weekend: "3"
        case .nextWeek: "4"
        case .none: "5"
        }
    }
}

public enum DateEntry {
    public static func parse(_ text: String, now: Date, calendar: Calendar) -> DateEntryResult {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count == 1, tokens[0].lowercased() == "none" { return .clear }
        let scanner = QuickAddScanner(tokens: tokens, now: now, calendar: calendar)
        let offset = scanner.word(0) == "at" ? 1 : 0
        guard let moment = scanner.parseMoment(at: offset, bareHourFirst: offset == 1),
              moment.consumed + offset == tokens.count,
              offset == 0 || moment.clock != nil
        else { return .invalid }
        guard let clock = moment.clock else {
            guard let day = moment.day else { return .invalid }
            return .date(calendar.startOfDay(for: day), hasTime: false)
        }
        let date = scanner.resolve(moment, defaultClock: .startOfDay)
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard components.hour == clock.hour % 24, components.minute == clock.minute else { return .invalid }
        return .date(date, hasTime: true)
    }

    public static func quickDate(_ choice: DateEntryQuickChoice, now: Date, calendar: Calendar) -> Date? {
        let tokens = choice == .nextWeek ? ["next", "week"] : [choice.rawValue]
        let scanner = QuickAddScanner(tokens: tokens, now: now, calendar: calendar)
        switch choice {
        case .today, .tomorrow, .nextWeek:
            return scanner.parseDate(at: 0)?.day
        case .weekend:
            if calendar.isDateInWeekend(scanner.today) { return scanner.today }
            guard let weekend = calendar.nextWeekend(startingAfter: scanner.today) else { return nil }
            return calendar.startOfDay(for: weekend.start)
        case .none:
            return nil
        }
    }
}
