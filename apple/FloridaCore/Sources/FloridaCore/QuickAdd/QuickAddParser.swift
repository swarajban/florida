import Foundation

/// What one line of quick-add text said about a task. Every field except `title` is nil when the
/// text did not mention it; the caller supplies its own defaults (inbox category, default duration,
/// medium priority) and resolves `categoryHint` against real categories when building a `TaskItem`.
public struct QuickAddDraft: Hashable, Sendable {
    public var title: String
    public var durationMinutes: Int?
    public var priority: Priority?
    /// Set together with `dueAt`: `.soft` for "by <date>" and bare dates, `.hard` for "due" / "deadline".
    public var deadlineType: DeadlineType?
    public var dueAt: Date?
    /// Earliest start: "after mon", "from tue", "starting friday", "start 11/20".
    public var startAt: Date?
    /// Fixed start from an explicit clock time without a by/due/after keyword: "at 3pm", "tue 10am".
    public var pinnedStart: Date?
    /// Text after `#`, e.g. "work" or "personal-finances"; matching it to a category is the caller's job.
    public var categoryHint: String?
    /// Where the task can be done, from `@errand`, `@home`, `@office` or `@computer`.
    public var context: TaskContext?
    /// Text after the first ` // ` or ` -- ` separator, untouched by the token grammar.
    public var notes: String?

    public init(
        title: String = "", durationMinutes: Int? = nil, priority: Priority? = nil,
        deadlineType: DeadlineType? = nil, dueAt: Date? = nil, startAt: Date? = nil,
        pinnedStart: Date? = nil, categoryHint: String? = nil, context: TaskContext? = nil, notes: String? = nil
    ) {
        self.title = title
        self.durationMinutes = durationMinutes
        self.priority = priority
        self.deadlineType = deadlineType
        self.dueAt = dueAt
        self.startAt = startAt
        self.pinnedStart = pinnedStart
        self.categoryHint = categoryHint
        self.context = context
        self.notes = notes
    }
}

/// Turns one line typed into the quick-add field into a `QuickAddDraft`. Pure and deterministic:
/// all date math uses `now` and `calendar`, whose `timeZone` decides what "17:00" means.
///
/// Grammar (case-insensitive, whitespace-separated tokens in any order; whatever is not consumed
/// becomes the title, with whitespace collapsed and leading/trailing punctuation trimmed):
///
/// - Duration: `2h`, `30m`, `45min`, `1h30m`, `1h30`, `1h 30m`, `1.5h`, `90 min`, `2 hours`,
///   `for 2h`, `~2h`. Only the first duration counts; later ones stay in the title.
/// - Priority: `!asap` `!urgent` `!high` `!h` `!med` `!medium` `!m` `!low` `!l`, or `p1`…`p4`
///   (asap, high, medium, low). A bare `asap` / `urgent` as the first or last word of the title
///   also means asap; in the middle of a sentence it is left alone.
/// - Category: `#slug` (letters, digits, `_`, `-`). The first one wins and is returned as `categoryHint`.
/// - Context: `@computer` `@errand` `@home` `@office`. The first one wins; any other `@word`
///   (a mention such as `@sam`) stays in the title.
/// - Dates: `today` `eod` `tomorrow` `tmrw` `tmr` `eow` (this Friday), `mon`…`sunday` (the next one
///   strictly after today), `next week` (Monday after the coming Sunday), `next fri`, `11/20`,
///   `11/20/2026`, `2026-11-20`, `nov 20`, `nov 20th`, `20 nov`, `nov 20 2026`. Month/day dates
///   without a year that already passed this year roll to next year.
/// - Soft deadline: `by <date>` or a bare date → `dueAt` at 17:00 on that day, `deadlineType = .soft`.
/// - Hard deadline: `due <date>` / `deadline <date>` → `.hard`. `by` and `due` take an optional
///   clock time: `by fri 3pm`, `by fri at 3pm`, `due tomorrow 9:30`, `by 5pm` (today if still
///   ahead, otherwise tomorrow).
/// - Earliest start: `after <date>`, `from <date>`, `starting <date>`, `start <date>` → `startAt`
///   at 00:00 on that day, or at the clock time if one follows.
/// - Pinned start: `at 3pm`, `tue 10am`, `tomorrow at 3pm`, `at 14:00`, `3pm tomorrow` → `pinnedStart`.
///   Clock forms: `3pm` `3:30pm` `3 pm` `15:00` `noon` `midnight`, plus a bare hour such as `9`
///   only directly after `at` or a date. A clock with no date means today, or tomorrow if that
///   time has already passed.
/// - Notes: everything after the first ` // ` or ` -- `.
public enum QuickAddParser {
    public static func parse(_ text: String, now: Date, calendar: Calendar) -> QuickAddDraft {
        let (body, notes) = QuickAddScanner.splitNotes(text)
        let tokens = body.split(whereSeparator: \.isWhitespace).map(String.init)
        let scanner = QuickAddScanner(tokens: tokens, now: now, calendar: calendar)
        var draft = QuickAddDraft(notes: notes)
        var title: [String] = []
        var i = 0

        while i < tokens.count {
            let word = scanner.words[i]

            if draft.categoryHint == nil, let slug = QuickAddScanner.categorySlug(tokens[i]) {
                draft.categoryHint = slug
                i += 1
                continue
            }
            if draft.context == nil, let context = QuickAddScanner.contexts[word] {
                draft.context = context
                i += 1
                continue
            }
            if draft.priority == nil, let priority = QuickAddScanner.explicitPriorities[word] {
                draft.priority = priority
                i += 1
                continue
            }
            if draft.durationMinutes == nil {
                let offset = word == "for" ? 1 : 0
                if let duration = scanner.parseDuration(at: i + offset) {
                    draft.durationMinutes = duration.minutes
                    i += offset + duration.consumed
                    continue
                }
            }
            if let deadline = QuickAddScanner.dueKeywords[word], draft.dueAt == nil,
               let moment = scanner.parseMoment(at: i + 1, bareHourFirst: false) {
                draft.dueAt = scanner.resolve(moment, defaultClock: .endOfWorkday)
                draft.deadlineType = deadline
                i += 1 + moment.consumed
                continue
            }
            if QuickAddScanner.startKeywords.contains(word), draft.startAt == nil,
               let moment = scanner.parseMoment(at: i + 1, bareHourFirst: false) {
                draft.startAt = scanner.resolve(moment, defaultClock: .startOfDay)
                i += 1 + moment.consumed
                continue
            }
            if word == "at", draft.pinnedStart == nil,
               let moment = scanner.parseMoment(at: i + 1, bareHourFirst: true), moment.clock != nil {
                draft.pinnedStart = scanner.resolve(moment, defaultClock: .startOfDay)
                i += 1 + moment.consumed
                continue
            }
            if let moment = scanner.parseMoment(at: i, bareHourFirst: false) {
                if moment.clock != nil {
                    if draft.pinnedStart == nil {
                        draft.pinnedStart = scanner.resolve(moment, defaultClock: .startOfDay)
                        i += moment.consumed
                        continue
                    }
                } else if draft.dueAt == nil {
                    draft.dueAt = scanner.resolve(moment, defaultClock: .endOfWorkday)
                    draft.deadlineType = .soft
                    i += moment.consumed
                    continue
                }
            }

            title.append(tokens[i])
            i += 1
        }

        // "asap: reply to Jane", "reply to Jane asap" — but not "the asap category".
        if draft.priority == nil, let first = title.first, let last = title.last {
            if QuickAddScanner.isBareUrgency(first) {
                title.removeFirst()
                draft.priority = .asap
            } else if QuickAddScanner.isBareUrgency(last) {
                title.removeLast()
                draft.priority = .asap
            }
        }

        draft.title = QuickAddScanner.joinTitle(title)
        return draft
    }
}

/// Token-level helpers behind `QuickAddParser`. Internal so tests can probe durations, clocks and
/// dates directly; `QuickAddParser.parse` is the only public entry point.
struct QuickAddScanner {
    /// A wall-clock time. `hour` is 24 for "midnight", meaning the end of the day it is attached to.
    struct Clock: Hashable {
        var hour: Int
        var minute: Int

        static let startOfDay = Clock(hour: 0, minute: 0)
        static let endOfWorkday = Clock(hour: TaskDay.dueHour, minute: 0)
    }

    /// A date and/or clock read from the tokens; at least one of the two is present.
    struct Moment: Hashable {
        /// Start of the named day in `calendar`, or nil when only a clock was given.
        var day: Date?
        var clock: Clock?
        var consumed: Int
    }

    enum DurationUnit: Hashable {
        case hours, minutes, mixed
    }

    /// Tokens as typed (for the title).
    let tokens: [String]
    /// Lowercased tokens (for matching).
    let words: [String]
    let now: Date
    let calendar: Calendar
    /// Start of the current day in `calendar`.
    let today: Date

    init(tokens: [String], now: Date, calendar: Calendar) {
        self.tokens = tokens
        self.words = tokens.map { $0.lowercased() }
        self.now = now
        self.calendar = calendar
        self.today = calendar.startOfDay(for: now)
    }

    init(text: String, now: Date, calendar: Calendar) {
        let body = Self.splitNotes(text).body
        self.init(tokens: body.split(whereSeparator: \.isWhitespace).map(String.init), now: now, calendar: calendar)
    }

    func word(_ i: Int) -> String? {
        words.indices.contains(i) ? words[i] : nil
    }

    // MARK: - Vocabulary

    static let explicitPriorities: [String: Priority] = [
        "!asap": .asap, "!urgent": .asap, "p1": .asap,
        "!high": .high, "!h": .high, "p2": .high,
        "!med": .medium, "!medium": .medium, "!m": .medium, "p3": .medium,
        "!low": .low, "!l": .low, "p4": .low,
    ]

    /// `@errand` and friends: one token per `TaskContext`, spelled like its raw value.
    static let contexts: [String: TaskContext] = Dictionary(
        uniqueKeysWithValues: TaskContext.allCases.map { ("@\($0.rawValue)", $0) }
    )

    static let dueKeywords: [String: DeadlineType] = ["by": .soft, "due": .hard, "deadline": .hard]
    static let startKeywords: Set<String> = ["after", "from", "starting", "start"]

    /// Foundation weekday numbers: 1 = Sunday … 7 = Saturday.
    static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1,
        "mon": 2, "monday": 2,
        "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6,
        "sat": 7, "saturday": 7,
    ]

    static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
        "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
        "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10,
        "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]

    /// Longest first so "hours" is not read as "h" + "ours".
    static let hourUnits = ["hours", "hour", "hrs", "hr", "h"]
    static let minuteUnits: Set<String> = ["m", "min", "mins", "minute", "minutes"]
    /// Units accepted as their own token after a number ("90 min"); a lone "m" is too easy to hit.
    static let spelledMinuteUnits: Set<String> = ["min", "mins", "minute", "minutes"]

    // MARK: - Notes, category, priority, title

    /// Splits at the first standalone `//` or `--` token. Notes keep their original text, trimmed.
    static func splitNotes(_ text: String) -> (body: Substring, notes: String?) {
        for token in text.split(whereSeparator: \.isWhitespace) where token == "//" || token == "--" {
            let notes = text[token.endIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
            return (text[..<token.startIndex], notes.isEmpty ? nil : notes)
        }
        return (text[...], nil)
    }

    /// `#slug` with slug in `[A-Za-z0-9_-]+`; returns the slug as typed.
    static func categorySlug(_ token: String) -> String? {
        guard token.hasPrefix("#") else { return nil }
        let slug = token.dropFirst()
        guard !slug.isEmpty,
              slug.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" || $0 == "-" })
        else { return nil }
        return String(slug)
    }

    /// "asap" / "urgent", allowing trailing punctuation such as "asap:" or "urgent!".
    static func isBareUrgency(_ token: String) -> Bool {
        var word = Substring(token.lowercased())
        while let last = word.last, last.isPunctuation {
            word = word.dropLast()
        }
        return word == "asap" || word == "urgent"
    }

    static func joinTitle(_ tokens: [String]) -> String {
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—:;,./|~"))
        return tokens.joined(separator: " ").trimmingCharacters(in: trim)
    }

    // MARK: - Duration

    /// A duration starting at `i`: one token (`2h`, `1h30m`, `1.5h`, `~45min`), two tokens
    /// (`90 min`, `2 hours`), optionally followed by a minutes part (`1h 30m`, `2 hours 15 min`).
    func parseDuration(at i: Int) -> (minutes: Int, consumed: Int)? {
        guard let first = durationPart(at: i) else { return nil }
        var minutes = first.minutes
        var consumed = first.consumed
        if first.unit == .hours, let tail = durationPart(at: i + consumed), tail.unit == .minutes {
            minutes += tail.minutes
            consumed += tail.consumed
        }
        let rounded = Int(minutes.rounded())
        return rounded > 0 ? (rounded, consumed) : nil
    }

    func durationPart(at i: Int) -> (minutes: Double, unit: DurationUnit, consumed: Int)? {
        guard let token = word(i) else { return nil }
        if let single = Self.durationPart(inToken: token) {
            return (single.minutes, single.unit, 1)
        }
        guard let number = Self.leadingNumber(Self.withoutApprox(token)), number.rest.isEmpty,
              let unit = word(i + 1)
        else { return nil }
        if Self.hourUnits.contains(unit) { return (number.value * 60, .hours, 2) }
        if Self.spelledMinuteUnits.contains(unit) { return (number.value, .minutes, 2) }
        return nil
    }

    /// `2h`, `2hr`, `2hours`, `1.5h`, `1h30`, `1h30m`, `30m`, `45min`, `~2h`. Anything with other
    /// letters attached ("2hour-long") is not a duration.
    static func durationPart(inToken token: String) -> (minutes: Double, unit: DurationUnit)? {
        guard let number = leadingNumber(withoutApprox(token)), !number.rest.isEmpty else { return nil }
        let rest = number.rest
        if let unit = hourUnits.first(where: { rest.hasPrefix($0) }) {
            let tail = rest.dropFirst(unit.count)
            if tail.isEmpty { return (number.value * 60, .hours) }
            guard let extra = leadingInteger(tail),
                  extra.rest.isEmpty || minuteUnits.contains(String(extra.rest))
            else { return nil }
            return (number.value * 60 + Double(extra.value), .mixed)
        }
        if minuteUnits.contains(String(rest)) { return (number.value, .minutes) }
        return nil
    }

    // MARK: - Clock

    /// A clock time starting at `i`: `3pm`, `3:30pm`, `3 pm`, `15:00`, `noon`, `midnight`, and a
    /// bare hour (`9`) only when `allowBareHour` is set, i.e. right after `at` or a date.
    func parseClock(at i: Int, allowBareHour: Bool) -> (clock: Clock, consumed: Int)? {
        guard let token = word(i) else { return nil }
        if token == "noon" { return (Clock(hour: 12, minute: 0), 1) }
        if token == "midnight" { return (Clock(hour: 24, minute: 0), 1) }
        if let suffix = word(i + 1), suffix == "am" || suffix == "pm",
           let clock = Self.clock(inToken: token + suffix, allowBareHour: false) {
            return (clock, 2)
        }
        if let clock = Self.clock(inToken: token, allowBareHour: allowBareHour) {
            return (clock, 1)
        }
        return nil
    }

    static func clock(inToken token: String, allowBareHour: Bool) -> Clock? {
        var body = Substring(token)
        var meridiem: Substring?
        if body.hasSuffix("am") || body.hasSuffix("pm") {
            meridiem = body.suffix(2)
            body = body.dropLast(2)
        }
        guard let hourPart = leadingInteger(body) else { return nil }
        let hour = hourPart.value
        let rest = hourPart.rest
        var minute = 0
        var hasColon = false
        if rest.hasPrefix(":") {
            let minutes = rest.dropFirst()
            guard minutes.count == 2, let minutePart = leadingInteger(minutes), minutePart.rest.isEmpty else { return nil }
            minute = minutePart.value
            hasColon = true
        } else if !rest.isEmpty {
            return nil
        }
        guard minute < 60 else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            return Clock(hour: hour % 12 + (meridiem == "pm" ? 12 : 0), minute: minute)
        }
        guard hasColon || allowBareHour, hour < 24 else { return nil }
        return Clock(hour: hour, minute: minute)
    }

    // MARK: - Date

    /// A calendar day starting at `i`, as the start of that day. Returns how many tokens it took
    /// (`next fri` and `nov 20` take two, `nov 20 2026` three).
    func parseDate(at i: Int) -> (day: Date, consumed: Int)? {
        guard let token = word(i) else { return nil }
        switch token {
        case "today", "eod":
            return (today, 1)
        case "tomorrow", "tmrw", "tmr":
            return (addDays(1, to: today), 1)
        case "eow":
            return (weekday(6, onOrAfter: today), 1)
        case "in":
            guard let number = word(i + 1), let count = Self.integer(number[...]),
                  count <= 10_000 * 366, let unit = word(i + 2)
            else { return nil }
            let component: Calendar.Component
            switch unit {
            case "day", "days": component = .day
            case "week", "weeks": component = .weekOfYear
            case "month", "months": component = .month
            default: return nil
            }
            guard let day = calendar.date(byAdding: component, value: count, to: today),
                  (1...9999).contains(calendar.component(.year, from: day))
            else { return nil }
            return (calendar.startOfDay(for: day), 3)
        case "next":
            guard let next = word(i + 1) else { return nil }
            let nextWeek = addDays(1, to: weekday(1, strictlyAfter: today))
            if next == "week" { return (nextWeek, 2) }
            if let target = Self.weekdays[next] { return (weekday(target, onOrAfter: nextWeek), 2) }
            return nil
        default:
            break
        }
        if let target = Self.weekdays[token] { return (weekday(target, strictlyAfter: today), 1) }
        if let day = numericDate(token) { return (day, 1) }
        return monthNameDate(at: i)
    }

    /// `<date> [at] <clock>`, `<date>`, or `<clock> [<date>]`. A bare hour counts as a clock
    /// after a date, or at the front when `bareHourFirst` is set (used after `at`).
    func parseMoment(at i: Int, bareHourFirst: Bool) -> Moment? {
        if let date = parseDate(at: i) {
            var moment = Moment(day: date.day, clock: nil, consumed: date.consumed)
            var j = i + date.consumed
            if word(j) == "at" { j += 1 }
            if parseDuration(at: j) == nil, let clock = parseClock(at: j, allowBareHour: true) {
                moment.clock = clock.clock
                moment.consumed = j + clock.consumed - i
            }
            return moment
        }
        if let clock = parseClock(at: i, allowBareHour: bareHourFirst) {
            var moment = Moment(day: nil, clock: clock.clock, consumed: clock.consumed)
            if let date = parseDate(at: i + clock.consumed) {
                moment.day = date.day
                moment.consumed += date.consumed
            }
            return moment
        }
        return nil
    }

    /// The instant a moment names. Without a day, a clock means today if still ahead of `now`,
    /// otherwise tomorrow.
    func resolve(_ moment: Moment, defaultClock: Clock) -> Date {
        let clock = moment.clock ?? defaultClock
        if let day = moment.day { return instant(on: day, clock: clock) }
        let candidate = instant(on: today, clock: clock)
        return candidate > now ? candidate : instant(on: addDays(1, to: today), clock: clock)
    }

    func instant(on day: Date, clock: Clock) -> Date {
        if clock.hour >= 24 { return addDays(1, to: day) }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = clock.hour
        components.minute = clock.minute
        return calendar.date(from: components) ?? day
    }

    func addDays(_ count: Int, to day: Date) -> Date {
        calendar.date(byAdding: .day, value: count, to: day) ?? day
    }

    func weekday(_ target: Int, onOrAfter day: Date) -> Date {
        let delta = (target - calendar.component(.weekday, from: day) + 7) % 7
        return addDays(delta, to: day)
    }

    func weekday(_ target: Int, strictlyAfter day: Date) -> Date {
        let delta = (target - calendar.component(.weekday, from: day) + 7) % 7
        return addDays(delta == 0 ? 7 : delta, to: day)
    }

    /// `11/20`, `11/20/2026`, `11/20/26` (month first), `2026-11-20`.
    func numericDate(_ word: String) -> Date? {
        if word.contains("/") {
            let parts = word.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3,
                  let month = Self.integer(parts[0]), let day = Self.integer(parts[1])
            else { return nil }
            if parts.count == 3 {
                guard parts[2].count == 2 || parts[2].count == 4, let year = Self.integer(parts[2]) else { return nil }
                return makeDay(year: parts[2].count == 2 ? 2000 + year : year, month: month, day: day)
            }
            return dayThisYearOrNext(month: month, day: day)
        }
        if word.contains("-") {
            let parts = word.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count == 4,
                  let year = Self.integer(parts[0]), let month = Self.integer(parts[1]), let day = Self.integer(parts[2])
            else { return nil }
            return makeDay(year: year, month: month, day: day)
        }
        return nil
    }

    /// `nov 20`, `nov 20th`, `20 nov`, `20th nov`, each with an optional 4-digit year after.
    func monthNameDate(at i: Int) -> (day: Date, consumed: Int)? {
        guard let first = word(i), let second = word(i + 1) else { return nil }
        let month: Int
        let day: Int
        if let m = Self.months[first], let d = Self.dayNumber(second) {
            month = m
            day = d
        } else if let d = Self.dayNumber(first), let m = Self.months[second] {
            month = m
            day = d
        } else {
            return nil
        }
        if let year = Self.yearNumber(word(i + 2)) {
            guard let date = makeDay(year: year, month: month, day: day) else { return nil }
            return (date, 3)
        }
        guard let date = dayThisYearOrNext(month: month, day: day) else { return nil }
        return (date, 2)
    }

    /// Start of the given day, or nil when the date does not exist (Feb 30).
    func makeDay(year: Int, month: Int, day: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// This year's month/day, or next year's when that already passed.
    func dayThisYearOrNext(month: Int, day: Int) -> Date? {
        let year = calendar.component(.year, from: today)
        if let date = makeDay(year: year, month: month, day: day), date >= today { return date }
        return makeDay(year: year + 1, month: month, day: day)
    }

    // MARK: - Lexical helpers

    /// `20`, `20th`, `1st`, `20,` → 20.
    static func dayNumber(_ word: String) -> Int? {
        var body = Substring(word)
        if body.hasSuffix(",") { body = body.dropLast() }
        guard let number = leadingInteger(body), ["", "st", "nd", "rd", "th"].contains(number.rest),
              (1...31).contains(number.value)
        else { return nil }
        return number.value
    }

    static func yearNumber(_ word: String?) -> Int? {
        guard let word, word.count == 4 else { return nil }
        return integer(Substring(word))
    }

    static func integer(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    static func leadingInteger(_ text: Substring) -> (value: Int, rest: Substring)? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard let value = integer(digits) else { return nil }
        return (value, text.dropFirst(digits.count))
    }

    /// `2`, `1.5` → Double; a leading digit is required (".5h" is not a duration).
    static func leadingNumber(_ text: Substring) -> (value: Double, rest: Substring)? {
        guard let whole = leadingInteger(text) else { return nil }
        guard whole.rest.hasPrefix(".") else { return (Double(whole.value), whole.rest) }
        let fractionDigits = whole.rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
        guard !fractionDigits.isEmpty, let value = Double("\(whole.value).\(fractionDigits)") else { return nil }
        return (value, whole.rest.dropFirst(1 + fractionDigits.count))
    }

    static func withoutApprox(_ word: String) -> Substring {
        word.hasPrefix("~") ? word.dropFirst() : word[...]
    }
}
