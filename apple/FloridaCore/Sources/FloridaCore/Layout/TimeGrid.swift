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
