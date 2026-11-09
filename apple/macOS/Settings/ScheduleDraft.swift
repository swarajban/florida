import FloridaKit
import Foundation

/// An editable schedule with its windows spread out per weekday, the way the editor shows them.
/// `windows()` folds them back into `ScheduleWindow`s, one per distinct start/end pair.
struct ScheduleDraft: Equatable {
    /// One window on one weekday, in minutes after midnight in the schedule's time zone.
    struct Window: Identifiable, Equatable {
        var id = UUID()
        var start: Int
        var end: Int
    }

    var name: String
    var timeZone: String
    /// Indexed by weekday, 0 = Sunday … 6 = Saturday, each sorted by start.
    var days: [[Window]]

    init(_ schedule: Schedule) {
        name = schedule.name
        timeZone = schedule.timeZone
        var days = Array(repeating: [Window](), count: 7)
        for window in schedule.windows {
            guard let start = ClockTime.minutes(window.start), let end = ClockTime.minutes(window.end) else { continue }
            for day in window.days where days.indices.contains(day) {
                days[day].append(Window(start: start, end: end))
            }
        }
        self.days = days.map { $0.sorted { $0.start < $1.start } }
    }

    /// Windows grouped by identical times, ordered by start: `[Mon–Fri 09:00–12:00, …]`.
    func windows() -> [ScheduleWindow] {
        var daysByTimes: [Pair: [Int]] = [:]
        for (day, windows) in days.enumerated() {
            for window in windows {
                daysByTimes[Pair(start: window.start, end: window.end), default: []].append(day)
            }
        }
        return daysByTimes
            .sorted { $0.key.start != $1.key.start ? $0.key.start < $1.key.start : $0.key.end < $1.key.end }
            .map {
                ScheduleWindow(
                    days: $0.value.sorted(), start: ClockTime.string(minutes: $0.key.start),
                    end: ClockTime.string(minutes: $0.key.end))
            }
    }

    /// Whether saving would change `schedule` (window ids and grouping aside).
    func differs(from schedule: Schedule) -> Bool {
        let original = ScheduleDraft(schedule)
        return name != original.name || timeZone != original.timeZone || windows() != original.windows()
    }

    /// Why the server would reject this draft, or nil when it can be saved.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the schedule a name" }
        if TimeZone(identifier: timeZone) == nil { return "Pick a time zone" }
        if days.allSatisfy(\.isEmpty) { return "Add at least one window" }
        for (day, windows) in days.enumerated() {
            if windows.contains(where: { $0.end <= $0.start }) {
                return "A \(Calendar.current.weekdaySymbols[day]) window ends before it starts"
            }
        }
        return nil
    }

    /// The editor's "+" for a day: after the day's last window when there is room, else 9–5.
    mutating func addWindow(on day: Int) {
        let after = days[day].map(\.end).max() ?? 0
        let window = after > 0 && after + 60 <= ClockTime.lastMinute
            ? Window(start: after + 60, end: min(after + 180, ClockTime.lastMinute))
            : Window(start: 9 * 60, end: 17 * 60)
        days[day].append(window)
        days[day].sort { $0.start < $1.start }
    }

    private struct Pair: Hashable {
        let start: Int
        let end: Int
    }
}
