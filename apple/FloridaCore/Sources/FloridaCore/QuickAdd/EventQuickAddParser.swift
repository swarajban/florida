import Foundation

public struct EventQuickAddDraft: Hashable, Sendable {
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var allDay: Bool
    public var recurrence: EventRecurrence?
    public var location: String?
    public var calendarHint: String?
    public var notes: String?

    public init(
        title: String, startAt: Date, endAt: Date, allDay: Bool = false,
        recurrence: EventRecurrence? = nil, location: String? = nil,
        calendarHint: String? = nil, notes: String? = nil
    ) {
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.recurrence = recurrence
        self.location = location
        self.calendarHint = calendarHint
        self.notes = notes
    }
}

public enum EventQuickAddParser {
    public static func parse(
        _ text: String, now: Date, calendar: Calendar, defaultStart: Date? = nil
    ) -> EventQuickAddDraft {
        let (body, notes) = QuickAddScanner.splitNotes(text)
        let scanner = QuickAddScanner(
            tokens: body.split(whereSeparator: \.isWhitespace).map(String.init), now: now, calendar: calendar)
        var day: Date?
        var clock: QuickAddScanner.Clock?
        var endClock: QuickAddScanner.Clock?
        var duration: Int?
        var recurrence: EventRecurrence?
        var recurringDay: Date?
        var allDay = false
        var location: String?
        var hint: String?
        var title: [String] = []
        var bareClockIndex: Int?
        var i = 0

        while i < scanner.tokens.count {
            let word = scanner.words[i]
            if hint == nil, word == "#" || QuickAddScanner.categorySlug(scanner.tokens[i]) != nil {
                hint = String(scanner.tokens[i].dropFirst())
                i += 1
                continue
            }
            if !allDay, let count = allDayLength(scanner, at: i) {
                allDay = true
                i += count
                continue
            }
            if let count = unsupportedRecurrenceLength(scanner, at: i) {
                title.append(contentsOf: scanner.tokens[i..<(i + count)])
                i += count
                continue
            }
            if recurrence == nil, let repeatRule = parseRecurrence(scanner, at: i) {
                recurrence = repeatRule.rule
                recurringDay = repeatRule.day
                i += repeatRule.consumed
                if recurringDay != nil { bareClockIndex = i }
                continue
            }
            if duration == nil {
                let offset = word == "for" ? 1 : 0
                if let parsed = scanner.parseDuration(at: i + offset) {
                    duration = parsed.minutes
                    i += offset + parsed.consumed
                    continue
                }
            }
            let dateOffset = word == "on" || word == "starting" || word == "from" ? 1 : 0
            if day == nil, let parsed = scanner.parseDate(at: i + dateOffset) {
                day = parsed.day
                i += dateOffset + parsed.consumed
                bareClockIndex = i
                continue
            }
            let clockOffset = word == "at" || word == "from" ? 1 : 0
            if clock == nil {
                if let range = parseRange(scanner, at: i + clockOffset) {
                    clock = range.start
                    endClock = range.end
                    i += clockOffset + range.consumed
                    continue
                }
                if let parsed = scanner.parseClock(
                    at: i + clockOffset, allowBareHour: clockOffset > 0 || bareClockIndex == i
                ) {
                    clock = parsed.clock
                    i += clockOffset + parsed.consumed
                    continue
                }
            }
            if word == "at", location == nil {
                var end = i + 1
                while end < scanner.tokens.count, !isLocationBoundary(scanner, at: end) { end += 1 }
                if end > i + 1 {
                    location = scanner.tokens[(i + 1)..<end].joined(separator: " ")
                    i = end
                    continue
                }
            }
            title.append(scanner.tokens[i])
            i += 1
        }

        let namedDay: Date?
        if let recurringDay, let day {
            namedDay = scanner.weekday(calendar.component(.weekday, from: recurringDay), onOrAfter: day)
        } else {
            namedDay = day ?? recurringDay
        }
        let start: Date
        let end: Date
        if allDay {
            let localDay = namedDay ?? calendar.startOfDay(for: defaultStart ?? now)
            start = AllDayDate.storedInstant(forLocalDay: localDay, calendar: calendar)
            end = AllDayDate.storedInstant(forLocalDay: scanner.addDays(1, to: localDay), calendar: calendar)
        } else {
            if let clock {
                start = scanner.resolve(
                    QuickAddScanner.Moment(day: namedDay, clock: clock, consumed: 0), defaultClock: clock)
            } else if let namedDay {
                start = scanner.instant(on: namedDay, clock: QuickAddScanner.Clock(hour: 9, minute: 0))
            } else {
                start = defaultStart ?? now
            }
            if let endClock {
                let startDay = calendar.startOfDay(for: start)
                let candidate = scanner.instant(on: startDay, clock: endClock)
                end = candidate > start ? candidate : scanner.instant(
                    on: scanner.addDays(1, to: startDay), clock: endClock)
            } else {
                end = start.addingTimeInterval(Double(duration ?? 30) * 60)
            }
        }
        return EventQuickAddDraft(
            title: QuickAddScanner.joinTitle(title), startAt: start, endAt: end, allDay: allDay,
            recurrence: recurrence, location: location, calendarHint: hint, notes: notes)
    }

    public static func matchingCalendars(
        hint: String, in calendars: [CalendarInfo], accounts: [GoogleAccount]
    ) -> [CalendarInfo] {
        let needle = normalize(hint)
        guard !needle.isEmpty else { return [] }
        let writable = calendars.filter { $0.accessRole == "owner" || $0.accessRole == "writer" }
        let candidates = writable.map { calendar in
            var names = [calendar.id, calendar.googleId, calendar.summary]
            if let account = accounts.first(where: {
                $0.id == calendar.accountId && normalize($0.email) == normalize(calendar.googleId)
            }) {
                names.append(account.label)
            }
            return (calendar, names.map(normalize))
        }
        let exact = candidates.filter { $0.1.contains(needle) }.map(\.0)
        if !exact.isEmpty { return exact }
        let slug = calendarSlug(hint)
        guard !slug.isEmpty else { return [] }
        let slugExact = candidates.filter { $0.1.contains { calendarSlug($0) == slug } }.map(\.0)
        if !slugExact.isEmpty { return slugExact }
        return candidates.filter { $0.1.contains { $0.hasPrefix(needle) || calendarSlug($0).hasPrefix(slug) } }.map(\.0)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func calendarSlug(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    private static func allDayLength(_ scanner: QuickAddScanner, at i: Int) -> Int? {
        if scanner.word(i) == "all-day" || scanner.word(i) == "allday" { return 1 }
        return scanner.word(i) == "all" && scanner.word(i + 1) == "day" ? 2 : nil
    }

    private static func parseRecurrence(
        _ scanner: QuickAddScanner, at i: Int
    ) -> (rule: EventRecurrence, day: Date?, consumed: Int)? {
        guard let word = scanner.word(i) else { return nil }
        if let frequency = EventRecurrence.Frequency(rawValue: word) {
            return (EventRecurrence(frequency: frequency, timeZone: scanner.calendar.timeZone.identifier), nil, 1)
        }
        guard word == "every" else { return nil }
        var j = i + 1
        var interval = 1
        if scanner.word(j) == "other" {
            interval = 2
            j += 1
        } else if let token = scanner.word(j), let number = QuickAddScanner.integer(token[...]) {
            guard (1...99).contains(number) else { return nil }
            interval = number
            j += 1
        }
        guard let unit = scanner.word(j) else { return nil }
        let singular = unit.hasSuffix("s") ? String(unit.dropLast()) : unit
        let frequency: EventRecurrence.Frequency
        var day: Date?
        if let weekday = QuickAddScanner.weekdays[unit] ?? QuickAddScanner.weekdays[singular] {
            frequency = .weekly
            day = scanner.weekday(weekday, strictlyAfter: scanner.today)
        } else {
            switch singular {
            case "day": frequency = .daily
            case "week": frequency = .weekly
            case "month": frequency = .monthly
            case "year": frequency = .yearly
            default: return nil
            }
        }
        return (EventRecurrence(
            frequency: frequency, interval: interval, timeZone: scanner.calendar.timeZone.identifier), day, j + 1 - i)
    }

    private static func unsupportedRecurrenceLength(_ scanner: QuickAddScanner, at i: Int) -> Int? {
        guard let first = scanner.word(i), first == "every" || EventRecurrence.Frequency(rawValue: first) != nil
        else { return nil }
        var j = i + 1
        if first == "every" {
            if let word = scanner.word(j), word == "other" || QuickAddScanner.integer(word[...]) != nil { j += 1 }
        } else if scanner.word(j) != "on" {
            return nil
        }
        let unitIndex = j
        if let word = scanner.word(j), ["day", "days", "week", "weeks", "month", "months", "year", "years"].contains(word) {
            j += 1
        }
        if scanner.word(j) == "on" { j += 1 }
        var weekdayCount = 0
        var lastWeekdayEnd = j
        while let word = scanner.word(j) {
            if word == "and" || word == "&" || word == "," || word == "/" {
                j += 1
                continue
            }
            let parts = word.split(whereSeparator: { $0 == "," || $0 == "/" || $0 == "&" })
            guard !parts.isEmpty, parts.allSatisfy({ QuickAddScanner.weekdays[String($0)] != nil }) else { break }
            weekdayCount += parts.count
            j += 1
            lastWeekdayEnd = j
        }
        if weekdayCount > 1 { return lastWeekdayEnd - i }
        if first == "every", parseRecurrence(scanner, at: i) == nil, weekdayCount == 1 {
            return lastWeekdayEnd - i
        }
        if first == "every", parseRecurrence(scanner, at: i) == nil, unitIndex < j {
            return j - i
        }
        return nil
    }

    private static func parseRange(
        _ scanner: QuickAddScanner, at i: Int
    ) -> (start: QuickAddScanner.Clock, end: QuickAddScanner.Clock, consumed: Int)? {
        guard i < scanner.tokens.count else { return nil }
        for count in stride(from: min(7, scanner.tokens.count - i), through: 1, by: -1) {
            let text = scanner.words[i..<(i + count)].joined(separator: " ").replacingOccurrences(of: " to ", with: "-")
            let halves = text.components(separatedBy: CharacterSet(charactersIn: "-–—"))
            guard halves.count == 2 else { continue }
            let left = QuickAddScanner(tokens: halves[0].split(whereSeparator: \.isWhitespace).map(String.init),
                                       now: scanner.now, calendar: scanner.calendar)
            let right = QuickAddScanner(tokens: halves[1].split(whereSeparator: \.isWhitespace).map(String.init),
                                        now: scanner.now, calendar: scanner.calendar)
            guard let first = left.parseClock(at: 0, allowBareHour: true), first.consumed == left.tokens.count,
                  let last = right.parseClock(at: 0, allowBareHour: true), last.consumed == right.tokens.count
            else { continue }
            var start = first.clock
            var end = last.clock
            let leftExplicit = halves[0].contains("am") || halves[0].contains("pm")
                || left.word(0) == "noon" || left.word(0) == "midnight"
            let rightExplicit = halves[1].contains("am") || halves[1].contains("pm")
                || right.word(0) == "noon" || right.word(0) == "midnight"
            if !leftExplicit, rightExplicit, (1...12).contains(start.hour) {
                start = inheritedClock(start, relativeTo: end, isStart: true)
            } else if !rightExplicit, (1...12).contains(end.hour) {
                end = inheritedClock(end, relativeTo: start, isStart: false)
            }
            return (start, end, count)
        }
        return nil
    }

    private static func inheritedClock(
        _ clock: QuickAddScanner.Clock, relativeTo other: QuickAddScanner.Clock, isStart: Bool
    ) -> QuickAddScanner.Clock {
        let choices = [clock.hour % 12, clock.hour % 12 + 12]
        let otherMinutes = other.hour * 60 + other.minute
        let hour = choices.min { lhs, rhs in
            func distance(_ hour: Int) -> Int {
                let minutes = hour * 60 + clock.minute
                let delta = ((isStart ? otherMinutes - minutes : minutes - otherMinutes) + 1440) % 1440
                return delta == 0 ? 1440 : delta
            }
            return distance(lhs) < distance(rhs)
        }!
        return QuickAddScanner.Clock(hour: hour, minute: clock.minute)
    }

    private static func isLocationBoundary(_ scanner: QuickAddScanner, at i: Int) -> Bool {
        guard scanner.tokens.indices.contains(i) else { return false }
        let word = scanner.words[i]
        return word.hasPrefix("#") || word == "at" || allDayLength(scanner, at: i) != nil
            || parseRecurrence(scanner, at: i) != nil || unsupportedRecurrenceLength(scanner, at: i) != nil
            || scanner.parseDate(at: i) != nil
            || scanner.parseDuration(at: i) != nil || scanner.parseClock(at: i, allowBareHour: false) != nil
            || parseRange(scanner, at: i) != nil
            || ((word == "for" || word == "on" || word == "from" || word == "starting")
                && isLocationBoundary(scanner, at: i + 1))
    }
}
