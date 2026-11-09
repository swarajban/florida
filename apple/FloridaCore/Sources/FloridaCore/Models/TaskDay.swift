import Foundation

/// A task's due date and "not before" date are whole days unless the user adds a clock time.
/// No flag is stored: the instant's wall-clock time in `calendar` says which. A deadline with no
/// time sits at 17:00, the end of the workday, which is also where quick add and the server's AI
/// parser put one; a repeating task without a due date gets the day's last minute from the
/// server. A "not before" date with no time is the day's first instant.
public enum TaskDay {
    /// The hour a deadline with no clock time is stored at.
    public static let dueHour = 17

    /// The instant stored for "due on the day containing `date`", with no time of its own.
    public static func due(on date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: dueHour, minute: 0, second: 0, of: day) ?? day
    }

    /// Whether `dueAt` carries a time the user chose, rather than one of the two whole-day defaults.
    public static func dueHasTime(_ dueAt: Date, calendar: Calendar) -> Bool {
        let clock = calendar.dateComponents([.hour, .minute], from: dueAt)
        let endOfWorkday = clock.hour == dueHour && clock.minute == 0
        let endOfDay = clock.hour == 23 && clock.minute == 59
        return !endOfWorkday && !endOfDay
    }

    /// The instant stored for "not before the day containing `date`": that day's first instant.
    public static func notBefore(on date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Whether `startAt` carries a time the user chose, rather than the start of its day.
    public static func notBeforeHasTime(_ startAt: Date, calendar: Calendar) -> Bool {
        startAt != calendar.startOfDay(for: startAt)
    }
}
