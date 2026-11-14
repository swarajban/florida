import Foundation

/// A task's due date and "not before" date are whole days unless the user adds a clock time.
/// No flag is stored: the instant's wall-clock time in `calendar` says which. A deadline with no
/// time sits at 17:00, the end of the workday, which is also where quick add and the server's AI
/// parser put one; a repeating task without a due date gets the day's last minute from the
/// server. A "not before" date with no time is the day's first instant.
public enum TaskDay {
    /// The hour a deadline with no clock time is stored at.
    public static let dueHour = 17

    public static func pushedToTomorrow(_ task: TaskItem, now: Date, calendar: Calendar) -> TaskItem {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        var task = task
        let start = max(task.startAt ?? tomorrow, tomorrow)
        task.startAt = start
        if let dueAt = task.dueAt {
            task.dueAt = due(dueAt, notBefore: start, calendar: calendar)
        }
        task.pinnedStart = nil
        return task
    }

    /// The instant stored for "due on the day containing `date`", with no time of its own.
    public static func due(on date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: dueHour, minute: 0, second: 0, of: day) ?? day
    }

    /// The due date offered before the user picks one: the next weekday after `now`, with no time
    /// of its own. Weekends are skipped because the routine never schedules on them.
    public static func defaultDue(now: Date, calendar: Calendar) -> Date {
        var day = calendar.startOfDay(for: now)
        repeat {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        } while calendar.isDateInWeekend(day)
        return due(on: day, calendar: calendar)
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

    /// The due date to keep once the task may not start before `startAt`. A due date still after
    /// the start stands. One the start has reached or passed leaves no time to do the task, so it
    /// moves to the day after the start, at the clock time it already had: a whole-day deadline
    /// stays whole-day, and "by 3 PM" stays 3 PM.
    public static func due(_ dueAt: Date, notBefore startAt: Date, calendar: Calendar) -> Date {
        guard startAt >= dueAt else { return dueAt }
        let startDay = calendar.startOfDay(for: startAt)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startDay) ?? startDay.addingTimeInterval(86_400)
        // Set, not added: on a day the clocks change, 17 hours after midnight is not 17:00.
        let clock = calendar.dateComponents([.hour, .minute, .second], from: dueAt)
        return calendar.date(
            bySettingHour: clock.hour ?? dueHour, minute: clock.minute ?? 0, second: clock.second ?? 0, of: nextDay)
            ?? due(on: nextDay, calendar: calendar)
    }
}
