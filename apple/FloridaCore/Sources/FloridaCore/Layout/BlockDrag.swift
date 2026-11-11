import Foundation

/// A timed block being dragged up or down a time grid: where it starts once the pointer has moved.
/// The block keeps its length, lands on a slot boundary, and stays inside the day.
public struct BlockDrag: Hashable, Sendable {
    /// Wall-clock minutes since midnight when the drag began.
    public let startMinute: Int
    public let durationMinutes: Int

    public init(startMinute: Int, durationMinutes: Int) {
        self.startMinute = startMinute
        self.durationMinutes = max(0, durationMinutes)
    }

    /// The start after the pointer moved `translation` points down (negative: up). Less than half
    /// a slot leaves the block where it was, so a slip of the hand does not move a 9:05 meeting
    /// to 9:00; from there the start is the slot boundary nearest to where the block was dragged.
    public func startMinute(movedBy translation: Double, grid: TimeGrid) -> Int {
        let slot = max(1, grid.slotMinutes)
        let moved = translation / grid.hourHeight * 60
        guard abs(moved) >= Double(slot) / 2 else { return startMinute }
        let snapped = Int(((Double(startMinute) + moved) / Double(slot)).rounded()) * slot
        let latest = max(0, DayLayout.minutesPerDay - durationMinutes)
        return min(max(snapped, 0), latest - latest % slot)
    }

    /// `minute` of `day` on the wall clock. A time a daylight-saving change skips is the next one
    /// that exists; one it repeats is the first of the two.
    public static func date(onDay day: Date, minute: Int, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: day)
        let clamped = min(max(minute, 0), DayLayout.minutesPerDay - 1)
        return calendar.date(
            bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: dayStart,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) ?? dayStart
    }
}
