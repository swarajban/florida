import Foundation

extension QuickAddScanner {
    enum SymbolValue {
        case due(Moment)
        case someday
        case start(Moment)
        case duration(Int)
        case recurrence(TaskRecurrence)
    }

    func symbolClause(at index: Int) -> (value: SymbolValue, consumed: Int)? {
        guard let token = word(index), let symbol = token.first, "^*=~".contains(symbol) else { return nil }
        var remainder = Array(tokens.dropFirst(index))
        let detached = token.count == 1
        if detached {
            remainder.removeFirst()
        } else {
            remainder[0] = String(remainder[0].dropFirst())
        }
        let scanner = QuickAddScanner(tokens: remainder, now: now, calendar: calendar)
        let offset = detached ? 1 : 0
        switch symbol {
        case "^":
            if scanner.word(0) == "none" || scanner.word(0) == "someday" { return (.someday, 1 + offset) }
            guard let moment = scanner.parseMoment(at: 0, bareHourFirst: false) else { return nil }
            return (.due(moment), moment.consumed + offset)
        case "=":
            guard let duration = scanner.parseDuration(at: 0) else { return nil }
            return (.duration(duration.minutes), duration.consumed + offset)
        case "~":
            if let duration = scanner.parseDuration(at: 0) {
                return (.duration(duration.minutes), duration.consumed + offset)
            }
            guard let moment = scanner.parseMoment(at: 0, bareHourFirst: false) else { return nil }
            return (.start(moment), moment.consumed + offset)
        case "*":
            guard let recurrence = scanner.parseTaskRecurrence() else { return nil }
            return (.recurrence(recurrence.rule), recurrence.consumed + offset)
        default:
            return nil
        }
    }

    private func parseTaskRecurrence() -> (rule: TaskRecurrence, consumed: Int)? {
        var frequency: TaskRecurrence.Frequency = .week
        var interval = 1
        var days: [Int]?
        var consumed = 1
        switch word(0) {
        case "daily": frequency = .day
        case "weekly": frequency = .week
        case "monthly": frequency = .month
        case "weekdays": days = [1, 2, 3, 4, 5]
        case "weekends": days = [0, 6]
        default:
            var index = word(0) == "every" ? 1 : 0
            if let token = word(index), let count = Self.integer(token[...]) {
                guard (1...999).contains(count) else { return nil }
                interval = count
                index += 1
            }
            switch word(index) {
            case "day", "days": frequency = .day
            case "week", "weeks": frequency = .week
            case "month", "months": frequency = .month
            default:
                guard interval == 1 else { return nil }
                var weekdays: [Int] = []
                while let token = word(index) {
                    let names = token.split(separator: ",", omittingEmptySubsequences: true)
                    let parsed = names.compactMap { Self.weekdays[String($0)].map { $0 - 1 } }
                    guard !names.isEmpty, parsed.count == names.count else { break }
                    weekdays.append(contentsOf: parsed)
                    index += 1
                }
                guard !weekdays.isEmpty else { return nil }
                days = Array(Set(weekdays)).sorted()
                index -= 1
            }
            consumed = index + 1
        }
        var rule = TaskRecurrence(
            frequency: frequency, interval: interval, timeZone: calendar.timeZone.identifier,
            startDate: "", weekdays: days)
        rule.startDate = rule.dateString(for: now)
        return (rule, consumed)
    }
}
