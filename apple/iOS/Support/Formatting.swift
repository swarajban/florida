import FloridaKit
import Foundation

/// Small text formatters shared by the agenda and task rows. Everything uses the user's locale
/// and the calendar passed in, so the output follows the device settings.
enum Formatting {
    /// "30m", "1h", "1h 30m".
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest)m"
        case (_, 0): return "\(hours)h"
        default: return "\(hours)h \(rest)m"
        }
    }

    /// "42 min" under an hour, otherwise `duration`'s "1h 30m" / "2h". For the free-gap rows.
    static func freeTime(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : duration(minutes: minutes)
    }

    /// "42 minutes", "1 hour 30 minutes", "2 hours"; for accessibility labels.
    static func spokenDuration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if rest > 0 || hours == 0 { parts.append(rest == 1 ? "1 minute" : "\(rest) minutes") }
        return parts.joined(separator: " ")
    }

    /// "9:00 AM" in the user's locale.
    static func time(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// "9:00 AM – 10:30 AM".
    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    /// "Today", "Tomorrow", "Yesterday", a weekday name within the coming week, otherwise
    /// "Nov 20" (with the year when it differs from `now`'s).
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let distance = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch distance {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            var style: Date.FormatStyle = (2...6).contains(distance) ? .dateTime.weekday(.wide)
                : sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year()
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
    }

    /// "Today 3:00 PM", "Fri 9:00 AM", "Nov 20 5:00 PM".
    static func dayAndTime(_ date: Date, now: Date, calendar: Calendar) -> String {
        "\(dayLabel(date, now: now, calendar: calendar)) \(time(date, calendar: calendar))"
    }

    /// A task's due date: the day alone ("Fri"), or with its time ("Fri 3:00 PM") when the user
    /// gave it one.
    static func due(_ dueAt: Date, now: Date, calendar: Calendar) -> String {
        TaskDay.dueHasTime(dueAt, calendar: calendar)
            ? dayAndTime(dueAt, now: now, calendar: calendar)
            : dayLabel(dueAt, now: now, calendar: calendar)
    }

    /// A task's "not before" date, printed like `due`.
    static func notBefore(_ startAt: Date, now: Date, calendar: Calendar) -> String {
        TaskDay.notBeforeHasTime(startAt, calendar: calendar)
            ? dayAndTime(startAt, now: now, calendar: calendar)
            : dayLabel(startAt, now: now, calendar: calendar)
    }
}
