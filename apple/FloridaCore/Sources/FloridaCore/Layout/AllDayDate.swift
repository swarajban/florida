import Foundation

/// Conversions between the server's all-day dates and local days. The server stores an all-day
/// event's date as UTC midnight of that date (`2026-11-10T00:00:00Z` for Nov 10) and its end as
/// UTC midnight of the day after the last one. Comparing those instants with local day bounds puts
/// the event on the wrong day (or two days) anywhere but UTC; these helpers map by calendar date.
public enum AllDayDate {
    /// The instant the server stores for the local calendar day containing `date`: UTC midnight
    /// of the same year, month and day.
    public static func storedInstant(forLocalDay date: Date, calendar: Calendar) -> Date {
        convert(date, from: calendar, to: utc)
    }

    /// The local days an all-day event covers, from the start of its first day up to the start of
    /// the day after its last, in `calendar`. `start` and `end` are the stored UTC-midnight instants;
    /// an end before the start is treated as the start.
    public static func localDays(start: Date, end: Date, calendar: Calendar) -> Range<Date> {
        let lower = convert(start, from: utc, to: calendar)
        let upper = convert(max(start, end), from: utc, to: calendar)
        return lower..<upper
    }

    /// The stored-instant range whose all-day events overlap the local `range`: an event with stored
    /// `start`/`end` covers some local day overlapping `range` exactly when
    /// `start < result.upperBound && end > result.lowerBound`.
    public static func storedRange(overlapping range: Range<Date>, calendar: Calendar) -> Range<Date> {
        let lower = storedInstant(forLocalDay: range.lowerBound, calendar: calendar)
        // The first day starting at or after the range's end; days from it on are outside.
        var endDay = calendar.startOfDay(for: range.upperBound)
        if endDay < range.upperBound {
            endDay = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay.addingTimeInterval(86_400)
        }
        let upper = storedInstant(forLocalDay: endDay, calendar: calendar)
        return lower..<max(lower, upper)
    }

    private static let utc = gregorian(TimeZone(identifier: "UTC")!)

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Start of the day in `target`'s time zone with the same Gregorian date as `date` has in
    /// `source`'s. Gregorian on both sides, so a Japanese or Buddhist user calendar maps the same.
    private static func convert(_ date: Date, from source: Calendar, to target: Calendar) -> Date {
        let source = gregorian(source.timeZone)
        let target = gregorian(target.timeZone)
        var components = source.dateComponents([.year, .month, .day], from: date)
        // Noon always exists; midnight can be skipped by a DST change in some zones.
        components.hour = 12
        guard let noon = target.date(from: components) else { return date }
        return target.startOfDay(for: noon)
    }
}
