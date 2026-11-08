import Foundation
@testable import FloridaCore

/// Fixed Gregorian calendar in America/Los_Angeles with Monday as the first weekday, shared by the
/// keyboard and layout tests. US DST ended on Sunday 2026-11-01 at 02:00 (PDT → PST).
enum PacificTestCalendar {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }
}
