import FloridaKit
import Foundation

/// Which hours of a local day fall inside some schedule's window. Windows are wall-clock "HH:MM"
/// in each schedule's own time zone, so a window can land on a different local day (or two)
/// than the weekday it names; every schedule date that can touch the local day is checked.
enum ScheduleHours {
    /// Local wall-clock minute ranges of `day` covered by any window of `schedules`, merged and
    /// sorted. Minutes match `DayLayout`'s, so the ranges line up with drawn blocks.
    static func workingMinutes(on day: Date, schedules: [Schedule], calendar: Calendar) -> [Range<Int>] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let localDate = calendar.dateComponents([.year, .month, .day], from: dayStart)
        var ranges: [Range<Int>] = []
        for schedule in schedules {
            guard let zone = TimeZone(identifier: schedule.timeZone) else { continue }
            var zoneCalendar = Calendar(identifier: .gregorian)
            zoneCalendar.timeZone = zone
            var noonComponents = localDate
            noonComponents.hour = 12
            guard let noon = zoneCalendar.date(from: noonComponents) else { continue }
            for offset in -1...1 {
                guard let date = zoneCalendar.date(byAdding: .day, value: offset, to: noon) else { continue }
                let midnight = zoneCalendar.startOfDay(for: date)
                let weekday = zoneCalendar.component(.weekday, from: date) - 1
                for window in schedule.windows where window.days.contains(weekday) {
                    guard let startMinute = ScheduleDraft.minutes(window.start),
                          let endMinute = ScheduleDraft.minutes(window.end), endMinute > startMinute,
                          let start = instant(minute: startMinute, after: midnight, calendar: zoneCalendar),
                          let end = instant(minute: endMinute, after: midnight, calendar: zoneCalendar)
                    else { continue }
                    let lower = max(start, dayStart)
                    let upper = min(end, dayEnd)
                    guard lower < upper else { continue }
                    let range = localMinute(lower, dayEnd: dayEnd, calendar: calendar)..<localMinute(upper, dayEnd: dayEnd, calendar: calendar)
                    if !range.isEmpty { ranges.append(range) }
                }
            }
        }
        return merged(ranges)
    }

    /// The instant of wall-clock `minute` after `midnight` in `calendar`'s zone; 1440 is the next midnight.
    private static func instant(minute: Int, after midnight: Date, calendar: Calendar) -> Date? {
        if minute >= DayLayout.minutesPerDay {
            return calendar.date(byAdding: .day, value: 1, to: midnight)
        }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: midnight)
    }

    private static func localMinute(_ date: Date, dayEnd: Date, calendar: Calendar) -> Int {
        if date >= dayEnd { return DayLayout.minutesPerDay }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
