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
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
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
        case 2...6: return date.formatted(.dateTime.weekday(.wide))
        default:
            if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
                return date.formatted(.dateTime.month(.abbreviated).day())
            }
            return date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }

    /// "Today 3:00 PM", "Fri 9:00 AM", "Nov 20 5:00 PM".
    static func dayAndTime(_ date: Date, now: Date, calendar: Calendar) -> String {
        "\(dayLabel(date, now: now, calendar: calendar)) \(time(date))"
    }
}
