import Foundation

/// One gutter label: the minute of the hour line it sits on and its text.
struct HourLabel: Hashable {
    let minute: Int
    let label: String
}

/// Gutter labels for hours 0…23, "1 PM" or "13" following the device's 12/24-hour setting the
/// way `Formatting.time` does (`TimeGrid.hourLabels()` is fixed English). Built on a mid-January
/// day so a DST change cannot skip an hour. Formats 24 dates, so `DayGridView` keeps the result
/// in state and nothing formats per frame.
enum HourLabels {
    static func make(calendar: Calendar) -> [HourLabel] {
        (0..<24).map { hour in
            let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: hour)) ?? Date()
            return HourLabel(minute: hour * 60, label: date.formatted(.dateTime.hour()))
        }
    }
}
