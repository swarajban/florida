import FloridaKit
import Foundation

/// Short display strings for dates and durations. Everything uses the autoupdating calendar and
/// time zone through `Date.FormatStyle`, so the UI follows system settings.
enum DateText {
    static func time(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// Gutter labels for hours 0…23, "1 PM" or "13" following the system's 12/24-hour setting the
    /// same way `time(_:)` does. Built on a fixed mid-January day so a DST change cannot skip an hour.
    /// Formats 24 dates, so `AppModel.hourLabels` caches it; the canvas never calls this per frame.
    static func hourLabels(calendar: Calendar) -> [(minute: Int, label: String)] {
        (0..<24).map { hour in
            let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: hour)) ?? Date()
            return (minute: hour * 60, label: date.formatted(.dateTime.hour()))
        }
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    /// "Today", "Tomorrow", "Yesterday", a weekday within the coming week, else "Nov 20".
    static func day(_ date: Date, calendar: Calendar, now: Date = Date()) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Tomorrow" }
        if days == -1 { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        var style: Date.FormatStyle = days > 1 && days < 7 ? .dateTime.weekday(.abbreviated)
            : sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// "Today 2:00 PM", "Tue 9:00 AM", "Nov 20 9:00 AM".
    static func dayAndTime(_ date: Date, calendar: Calendar, now: Date = Date()) -> String {
        "\(day(date, calendar: calendar, now: now)) \(time(date, calendar: calendar))"
    }

    /// A task's due date: the day alone ("Fri"), or with its time ("Fri 3:00 PM") when the user
    /// gave it one (see `TaskDay`).
    static func due(_ dueAt: Date, calendar: Calendar, now: Date = Date()) -> String {
        TaskDay.dueHasTime(dueAt, calendar: calendar)
            ? dayAndTime(dueAt, calendar: calendar, now: now)
            : day(dueAt, calendar: calendar, now: now)
    }

    /// A task's "not before" date, printed like `due`.
    static func notBefore(_ startAt: Date, calendar: Calendar, now: Date = Date()) -> String {
        TaskDay.notBeforeHasTime(startAt, calendar: calendar)
            ? dayAndTime(startAt, calendar: calendar, now: now)
            : day(startAt, calendar: calendar, now: now)
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
