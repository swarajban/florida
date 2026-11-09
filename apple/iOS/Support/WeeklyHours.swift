import FloridaKit
import Foundation

/// A schedule's windows as an editor sees them: a list of time ranges per weekday. Converts from
/// and back to `ScheduleWindow`s, which group the days sharing one range; validates as the server
/// does (`HH:MM` from 00:00 to 23:59, end after start, at least one window).
struct WeeklyHours: Hashable {
    /// Minutes after midnight, `start < end`, both within one day.
    struct Range: Hashable, Identifiable {
        var id = UUID()
        var start: Int
        var end: Int

        static func == (lhs: Range, rhs: Range) -> Bool {
            lhs.start == rhs.start && lhs.end == rhs.end
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(start)
            hasher.combine(end)
        }
    }

    static let lastMinute = 23 * 60 + 59

    /// Index 0 = Sunday … 6 = Saturday, as `ScheduleWindow.days`.
    var days: [[Range]] = Array(repeating: [], count: 7)

    init(windows: [ScheduleWindow]) {
        for window in windows {
            guard let start = Self.minutes(window.start), let end = Self.minutes(window.end) else { continue }
            for day in window.days where (0..<7).contains(day) {
                days[day].append(Range(start: start, end: end))
            }
        }
        for day in 0..<7 {
            days[day].sort { $0.start < $1.start }
        }
    }

    /// Days with the same set of ranges become one window per range, ordered by start then days.
    var windows: [ScheduleWindow] {
        var daysByRange: [Range: [Int]] = [:]
        for (day, ranges) in days.enumerated() {
            for range in Set(ranges) {
                daysByRange[range, default: []].append(day)
            }
        }
        return daysByRange
            .sorted { lhs, rhs in
                lhs.key.start != rhs.key.start ? lhs.key.start < rhs.key.start
                    : lhs.key.end != rhs.key.end ? lhs.key.end < rhs.key.end
                    : lhs.value.lexicographicallyPrecedes(rhs.value)
            }
            .map { ScheduleWindow(days: $0.value.sorted(), start: Self.clock($0.key.start), end: Self.clock($0.key.end)) }
    }

    /// Why the server would refuse these hours, or nil when it would accept them.
    var problem: String? {
        if days.allSatisfy(\.isEmpty) {
            return "Add at least one window of hours."
        }
        for (day, ranges) in days.enumerated() {
            let name = Calendar(identifier: .gregorian).weekdaySymbols[day]
            if ranges.contains(where: { $0.end <= $0.start }) {
                return "On \(name), a window ends before it starts."
            }
            let sorted = ranges.sorted { $0.start < $1.start }
            for (earlier, later) in zip(sorted, sorted.dropFirst()) where later.start < earlier.end {
                return "On \(name), two windows overlap."
            }
        }
        return nil
    }

    /// Copies one day's ranges onto other days, replacing theirs.
    mutating func copy(day: Int, to targets: [Int]) {
        for target in targets where target != day {
            days[target] = days[day].map { Range(start: $0.start, end: $0.end) }
        }
    }

    /// A new range after the day's last one: 09:00–17:00 on an empty day, otherwise an hour
    /// starting where the last ends (clamped to the end of the day).
    mutating func addRange(day: Int) {
        let start = days[day].map(\.end).max().map { min($0, Self.lastMinute - 60) } ?? 9 * 60
        let end = days[day].isEmpty ? 17 * 60 : min(start + 60, Self.lastMinute)
        days[day].append(Range(start: start, end: end))
    }

    /// "09:30" → 570.
    static func minutes(_ clock: String) -> Int? {
        let parts = clock.split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0..<24).contains(hours), (0..<60).contains(minutes)
        else { return nil }
        return hours * 60 + minutes
    }

    /// 570 → "09:30".
    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
