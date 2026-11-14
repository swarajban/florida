import FloridaKit
import Foundation

enum WidgetFormatting {
    static func taskDateLabel(_ date: TaskListDate, now: Date, calendar: Calendar) -> String {
        let day = dayLabel(date.date, now: now, calendar: calendar)
        switch date {
        case .due: return day
        case .pinned: return "Pinned \(day)"
        case .start: return "Start \(day)"
        }
    }

    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let distance = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        var weekday = Date.FormatStyle.dateTime.weekday(.abbreviated)
        weekday.timeZone = calendar.timeZone
        var monthDay = Date.FormatStyle.dateTime.month(.abbreviated).day()
        monthDay.timeZone = calendar.timeZone
        switch distance {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return date.formatted(weekday)
        default: return date.formatted(monthDay)
        }
    }
}
