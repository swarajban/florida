import Foundation

/// Short display strings for dates and durations. Everything uses the autoupdating calendar and
/// time zone through `Date.FormatStyle`, so the UI follows system settings.
enum DateText {
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    /// "Today", "Tomorrow", "Yesterday", a weekday within the coming week, else "Nov 20".
    static func day(_ date: Date, calendar: Calendar, now: Date = Date()) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        if let days = calendar.dateComponents([.day], from: today, to: day).day, days > 0, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "Today 2:00 PM", "Tue 9:00 AM", "Nov 20 9:00 AM".
    static func dayAndTime(_ date: Date, calendar: Calendar, now: Date = Date()) -> String {
        "\(day(date, calendar: calendar, now: now)) \(time(date))"
    }

    /// "November 2026".
    static func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    /// "Sunday, November 8, 2026".
    static func longDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    /// "Nov 8 – 14, 2026" or "Nov 29 – Dec 5, 2026" for a half-open range of whole days.
    static func rangeTitle(_ range: Range<Date>, calendar: Calendar) -> String {
        let first = range.lowerBound
        let last = calendar.date(byAdding: .day, value: -1, to: range.upperBound) ?? first
        let firstText = first.formatted(.dateTime.month(.abbreviated).day())
        if calendar.isDate(first, equalTo: last, toGranularity: .month) {
            return "\(firstText) – \(last.formatted(.dateTime.day())), \(last.formatted(.dateTime.year()))"
        }
        return "\(firstText) – \(last.formatted(.dateTime.month(.abbreviated).day())), \(last.formatted(.dateTime.year()))"
    }

    /// "45m", "1h", "1h 30m".
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest)m"
        case (_, 0): return "\(hours)h"
        default: return "\(hours)h \(rest)m"
        }
    }
}
