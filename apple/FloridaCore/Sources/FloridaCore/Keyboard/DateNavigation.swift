import Foundation

public enum CalendarViewMode: String, Hashable, Sendable, CaseIterable {
    case day, threeDays, week, month
}

/// Pure date arithmetic for the calendar views. Every result is a local midnight in `calendar`'s
/// time zone; days are added with `Calendar` so DST transitions keep midnight at midnight.
public enum DateNavigation {
    public static func startOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Adds calendar days, so the result keeps the wall-clock time across DST changes.
    public static func shift(_ date: Date, by days: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// Midnight of the first day of the week containing `date`, honoring `calendar.firstWeekday`.
    public static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
        let day = startOfDay(date, calendar: calendar)
        let weekday = calendar.component(.weekday, from: day)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return shift(day, by: -offset, calendar: calendar)
    }

    /// The seven local midnights of the week containing `weekContaining`.
    public static func days(in weekContaining: Date, calendar: Calendar) -> [Date] {
        let start = startOfWeek(for: weekContaining, calendar: calendar)
        return (0..<7).map { shift(start, by: $0, calendar: calendar) }
    }

    /// Every local midnight from the day containing `range.lowerBound` up to (not including) `range.upperBound`.
    public static func days(in range: Range<Date>, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var day = startOfDay(range.lowerBound, calendar: calendar)
        while day < range.upperBound {
            result.append(day)
            let next = shift(day, by: 1, calendar: calendar)
            guard next > day else { break }
            day = next
        }
        return result
    }

    /// The half-open range of instants a view shows around `anchor`: the anchor's day, three days
    /// from it, its week, or the 6-week month grid starting at the week containing the 1st.
    public static func visibleRange(for view: CalendarViewMode, anchor: Date, calendar: Calendar) -> Range<Date> {
        switch view {
        case .day:
            let start = startOfDay(anchor, calendar: calendar)
            return start..<shift(start, by: 1, calendar: calendar)
        case .threeDays:
            let start = startOfDay(anchor, calendar: calendar)
            return start..<shift(start, by: 3, calendar: calendar)
        case .week:
            let start = startOfWeek(for: anchor, calendar: calendar)
            return start..<shift(start, by: 7, calendar: calendar)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: anchor)
            let firstOfMonth = calendar.date(from: components) ?? startOfDay(anchor, calendar: calendar)
            let start = startOfWeek(for: firstOfMonth, calendar: calendar)
            return start..<shift(start, by: 42, calendar: calendar)
        }
    }
}
