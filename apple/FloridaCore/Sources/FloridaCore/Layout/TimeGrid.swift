import Foundation

/// Converts minutes <-> points for a vertical time grid and snaps to a slot.
public struct TimeGrid: Hashable, Sendable {
    /// Points per hour.
    public var hourHeight: Double
    /// Snapping granularity in minutes.
    public var slotMinutes: Int

    public init(hourHeight: Double = 60, slotMinutes: Int = 15) {
        self.hourHeight = hourHeight
        self.slotMinutes = slotMinutes
    }

    public var dayHeight: Double { hourHeight * 24 }

    public func y(forMinute minute: Int) -> Double {
        Double(minute) * hourHeight / 60
    }

    /// The minute containing `y` (not snapped), clamped to 0...1440.
    public func minute(forY y: Double) -> Int {
        clamp(Int((y / hourHeight * 60).rounded(.down)))
    }

    /// The nearest slot boundary to `y`, clamped to 0...1440.
    public func snappedMinute(forY y: Double) -> Int {
        let slot = Double(max(1, slotMinutes))
        let minutes = y / hourHeight * 60
        return clamp(Int((minutes / slot).rounded() * slot))
    }

    public func eventStartMinute(forY y: Double) -> Int {
        min(snappedMinute(forY: y), DayLayout.minutesPerDay - eventSlotMinutes)
    }

    public func eventMinutes(from startY: Double, to endY: Double) -> ClosedRange<Int> {
        let anchor = snappedMinute(forY: startY)
        let edge = snappedMinute(forY: endY)
        if edge != anchor { return min(anchor, edge)...max(anchor, edge) }
        if (endY < startY && anchor > 0) || anchor == DayLayout.minutesPerDay {
            return max(0, anchor - eventSlotMinutes)...anchor
        }
        return anchor...min(DayLayout.minutesPerDay, anchor + eventSlotMinutes)
    }

    public func eventDates(on day: Date, minutes: ClosedRange<Int>, calendar: Calendar) -> ClosedRange<Date> {
        let start = BlockDrag.date(onDay: day, minute: minutes.lowerBound, calendar: calendar)
        let midnight = calendar.dateInterval(of: .day, for: day)?.end
        let end = minutes.upperBound == DayLayout.minutesPerDay
            ? midnight ?? start
            : BlockDrag.date(onDay: day, minute: minutes.upperBound, calendar: calendar)
        return start...max(end, start.addingTimeInterval(Double(eventSlotMinutes) * 60))
    }

    private var eventSlotMinutes: Int { min(max(slotMinutes, 1), DayLayout.minutesPerDay) }

    private func clamp(_ minute: Int) -> Int {
        min(max(minute, 0), DayLayout.minutesPerDay)
    }

    /// Hour labels 0...23 as (minute, label) in a fixed English short format: "12 AM", "1 AM", …,
    /// "12 PM", …, "11 PM". The UI can localize later.
    public static func hourLabels() -> [(minute: Int, label: String)] {
        (0..<24).map { hour in
            let twelveHour = hour % 12 == 0 ? 12 : hour % 12
            let suffix = hour < 12 ? "AM" : "PM"
            return (minute: hour * 60, label: "\(twelveHour) \(suffix)")
        }
    }
}
