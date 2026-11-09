import Foundation

/// Wall-clock "HH:MM" strings, the form `ScheduleWindow` keeps its bounds in, as minutes after
/// midnight. Shared by the schedule editor and the grid's off-hours shading.
enum ClockTime {
    /// The latest minute the server accepts: a window ends at "23:59" at most.
    static let lastMinute = 23 * 60 + 59

    /// "09:30" → 570; nil for anything that is not "HH:MM" within a day. "24:00", which older
    /// rows may still hold, is the next midnight (1440).
    static func minutes(_ clock: String) -> Int? {
        let parts = clock.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return min(hour * 60 + minute, 24 * 60)
    }

    /// 570 → "09:30", clamped to "00:00"…"23:59".
    static func string(minutes: Int) -> String {
        let clamped = min(max(minutes, 0), lastMinute)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}
