import Foundation

/// A calendar-date rule, evaluated by the server in its IANA time zone. Each occurrence is a
/// separate TaskItem; completion never changes the rule or completes another occurrence.
public struct TaskRecurrence: Codable, Hashable, Sendable {
    public enum Frequency: String, Codable, Hashable, Sendable, CaseIterable {
        case day, week, month
    }

    public var frequency: Frequency
    public var interval: Int
    public var timeZone: String
    public var startDate: String
    /// Sunday = 0 … Saturday = 6. Nil uses the anchor date's weekday.
    public var weekdays: [Int]?
    /// Nil uses the anchor date's day. Shorter months use their last day.
    public var dayOfMonth: Int?
    /// Inclusive logical date, not an instant.
    public var endDate: String?

    public init(
        frequency: Frequency, interval: Int = 1, timeZone: String, startDate: String,
        weekdays: [Int]? = nil, dayOfMonth: Int? = nil, endDate: String? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.timeZone = timeZone
        self.startDate = startDate
        self.weekdays = weekdays
        self.dayOfMonth = dayOfMonth
        self.endDate = endDate
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    public func dateString(for date: Date) -> String {
        dateFormatter.string(from: date)
    }

    public func date(for logicalDate: String) -> Date? {
        let parts = logicalDate.split(separator: "-").compactMap { Int($0) }
        guard logicalDate.count == 10, parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              dateString(for: date) == logicalDate else { return nil }
        return calendar.startOfDay(for: date)
    }

    public var effectiveWeekdays: [Int] {
        if let weekdays { return Array(Set(weekdays)).sorted() }
        return date(for: startDate).map { [calendar.component(.weekday, from: $0) - 1] } ?? []
    }

    public var effectiveDayOfMonth: Int {
        dayOfMonth ?? date(for: startDate).map { calendar.component(.day, from: $0) } ?? 1
    }

    /// The first matching date, ignoring the optional end so validation can explain invalid ends.
    public var firstOccurrence: Date? {
        guard let start = date(for: startDate) else { return nil }
        return matchingOccurrence(onOrAfter: start)
    }

    /// Editor preview of an upcoming date. Past dates are not backfilled by the server.
    public func nextOccurrence(onOrAfter instant: Date) -> Date? {
        guard let next = matchingOccurrence(onOrAfter: instant), dateString(for: next).count == 10 else { return nil }
        if let endDate {
            guard let end = date(for: endDate), next <= end else { return nil }
        }
        return next
    }

    /// Interval weeks are anchored to the Monday-start week containing startDate.
    private func matchingOccurrence(onOrAfter instant: Date) -> Date? {
        guard (1...999).contains(interval), let start = date(for: startDate) else { return nil }
        let lower = max(start, calendar.startOfDay(for: instant))
        switch frequency {
        case .day:
            let days = calendar.dateComponents([.day], from: start, to: lower).day ?? 0
            let steps = (days + interval - 1) / interval
            return calendar.date(byAdding: .day, value: steps * interval, to: start)
        case .week:
            let anchorWeekday = (calendar.component(.weekday, from: start) + 5) % 7
            let weekdays = effectiveWeekdays
            guard !weekdays.isEmpty, weekdays.allSatisfy({ (0...6).contains($0) }),
                  let monday = calendar.date(byAdding: .day, value: -anchorWeekday, to: start) else { return nil }
            let elapsed = calendar.dateComponents([.day], from: monday, to: lower).day ?? 0
            let week = elapsed / 7
            let activeWeek = week + (interval - week % interval) % interval
            let days = weekdays.map { ($0 + 6) % 7 }.sorted()
            let offset = days.map { activeWeek * 7 + $0 }.first(where: { $0 >= elapsed })
                ?? ((activeWeek + interval) * 7 + days[0])
            return calendar.date(byAdding: .day, value: offset, to: monday)
        case .month:
            guard (1...31).contains(effectiveDayOfMonth),
                  let anchorMonth = calendar.dateInterval(of: .month, for: start)?.start,
                  let lowerMonth = calendar.dateInterval(of: .month, for: lower)?.start else { return nil }
            let months = calendar.dateComponents([.month], from: anchorMonth, to: lowerMonth).month ?? 0
            let steps = (months + interval - 1) / interval
            guard let month = calendar.date(byAdding: .month, value: steps * interval, to: anchorMonth) else { return nil }
            func occurrence(in month: Date) -> Date? {
                guard let days = calendar.range(of: .day, in: .month, for: month) else { return nil }
                return calendar.date(byAdding: .day, value: min(effectiveDayOfMonth, days.count) - 1, to: month)
            }
            guard let candidate = occurrence(in: month) else { return nil }
            if candidate >= lower { return candidate }
            return calendar.date(byAdding: .month, value: interval, to: month).flatMap(occurrence)
        }
    }

    public var validationMessage: String? {
        guard TimeZone(identifier: timeZone) != nil else { return "Choose a valid time zone." }
        guard (1...999).contains(interval) else { return "Repeat interval must be between 1 and 999." }
        guard date(for: startDate) != nil else { return "Choose a valid start date." }
        if let weekdays, frequency != .week || Set(weekdays).count != weekdays.count {
            return "Choose unique weekdays for a weekly repeat."
        }
        if dayOfMonth != nil && frequency != .month { return "Day of month requires a monthly repeat." }
        guard let firstOccurrence else { return "Choose valid repeat days." }
        if let endDate {
            guard let end = date(for: endDate) else { return "Choose a valid end date." }
            if end < firstOccurrence { return "The end date must include at least one occurrence." }
        }
        return nil
    }

    /// Existing series may have ended; enabling a new series requires an upcoming date.
    public func validationMessage(asNewSeriesAt instant: Date) -> String? {
        validationMessage ?? (nextOccurrence(onOrAfter: instant) == nil ? "The repeat rule has no upcoming occurrences." : nil)
    }

    public var summary: String {
        let unit: String
        switch frequency {
        case .day: unit = interval == 1 ? "day" : "\(interval) days"
        case .week: unit = interval == 1 ? "week" : "\(interval) weeks"
        case .month: unit = interval == 1 ? "month" : "\(interval) months"
        }
        var text = "Every \(unit)"
        if frequency == .week {
            let symbols: [String] = DateFormatter().shortWeekdaySymbols
            let days = effectiveWeekdays.compactMap { symbols.indices.contains($0) ? symbols[$0] : nil }
            text += " on " + days.joined(separator: ", ")
        } else if frequency == .month {
            text += " on day \(effectiveDayOfMonth) (last day in shorter months)"
        }
        text += " · starts \(startDate)"
        if let endDate { text += " · through \(endDate), inclusive" }
        return text
    }
}

extension TaskItem {
    /// When enabling repeats, line up the input dates with the rule's startDate anchor.
    /// The server shifts this template to the first matching occurrence; shifting here as well
    /// would double-shift rules whose first matching date is later than their startDate.
    /// Existing clock times are retained in the rule's zone; missing times use the server's
    /// midnight/end-of-day defaults. Server-owned membership/date are never fabricated here.
    public mutating func prepareToEnableRecurrence() {
        guard let recurrence, let anchor = recurrence.date(for: recurrence.startDate) else { return }
        if someday {
            dueAt = nil
            pinnedStart = nil
            deadlineType = .none
            return
        }
        let calendar = recurrence.calendar
        func onAnchorDay(_ instant: Date) -> Date {
            let clock = calendar.dateComponents([.hour, .minute, .second], from: instant)
            return calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0,
                                 second: clock.second ?? 0, of: anchor) ?? anchor
        }
        startAt = startAt.map(onAnchorDay) ?? anchor
        let next = calendar.date(byAdding: .day, value: 1, to: anchor) ?? anchor.addingTimeInterval(86_400)
        dueAt = dueAt.map(onAnchorDay) ?? calendar.startOfDay(for: next).addingTimeInterval(-0.001)
        if let startAt, let dueAt, startAt > dueAt {
            self.startAt = anchor
        }
        pinnedStart = pinnedStart.map(onAnchorDay)
        if deadlineType == .none { deadlineType = .soft }
    }
}
