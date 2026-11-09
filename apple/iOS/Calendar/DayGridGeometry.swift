import FloridaKit
import SwiftUI

/// Points for the hour grid: the label gutter on the left, then equal day columns. Shared by the
/// canvas, the block positions, the empty-slot tap and the drag, so a finger lands on what was
/// drawn. The iOS counterpart of the Mac's `GridGeometry`; minutes <-> points is `TimeGrid`.
struct DayGridGeometry: Equatable {
    let width: CGFloat
    let gutterWidth: CGFloat
    let dayCount: Int
    let grid: TimeGrid

    /// Blocks are drawn at least this tall (and laid out as if that long), so a 15-minute item is
    /// still a tap target under a finger.
    static let minimumBlockHeight: CGFloat = 22

    var dayHeight: CGFloat { CGFloat(grid.dayHeight) }

    var columnWidth: CGFloat {
        dayCount > 0 ? max(0, width - gutterWidth) / CGFloat(dayCount) : 0
    }

    /// The span `DayLayout` gives every block at least: `minimumBlockHeight` in minutes, never
    /// under one slot.
    static func minimumMinutes(for grid: TimeGrid) -> Int {
        let minutes = (Double(minimumBlockHeight) / grid.hourHeight * 60).rounded(.up)
        return max(grid.slotMinutes, Int(minutes))
    }

    /// Blocks this tall show their time range under the title (34 pt at the default hour height).
    var timeTextHeight: CGFloat { CGFloat(grid.hourHeight) * 34 / 60 }

    func x(forDay index: Int) -> CGFloat {
        gutterWidth + CGFloat(index) * columnWidth
    }

    func columnRect(forDay index: Int) -> CGRect {
        CGRect(x: x(forDay: index), y: 0, width: columnWidth, height: dayHeight)
    }

    /// The block's frame, inset a point so neighbours do not touch.
    func rect(for block: DayGridLayout.Block) -> CGRect {
        rect(dayIndex: block.dayIndex, column: block.column, columnCount: block.columnCount,
             startMinute: block.startMinute, endMinute: block.endMinute)
    }

    func rect(dayIndex: Int, column: Int, columnCount: Int, startMinute: Int, endMinute: Int) -> CGRect {
        let width = columnWidth / CGFloat(max(columnCount, 1))
        let x = x(forDay: dayIndex) + CGFloat(column) * width
        let y = CGFloat(grid.y(forMinute: startMinute))
        let height = CGFloat(grid.y(forMinute: endMinute)) - y
        return CGRect(x: x + 1, y: y + 0.5, width: max(width - 2, 2), height: max(height - 1, 4))
    }

    /// The day column under `x`; nil over the gutter or past the last column.
    func dayIndex(atX x: CGFloat) -> Int? {
        guard x >= gutterWidth, columnWidth > 0 else { return nil }
        let index = Int((x - gutterWidth) / columnWidth)
        return index < dayCount ? index : nil
    }

    /// The column nearest `x`, for a dragged block whose centre left the columns: over the gutter
    /// it is the first day, past the right edge the last.
    func nearestDayIndex(atX x: CGFloat) -> Int {
        guard dayCount > 0 else { return 0 }
        return dayIndex(atX: x) ?? (x < gutterWidth ? 0 : dayCount - 1)
    }

    /// The slot a tap on empty grid stands for: the nearest slot boundary, kept one slot above
    /// midnight so the new item starts inside the day.
    func slotMinute(atY y: CGFloat) -> Int {
        min(grid.snappedMinute(forY: Double(y)), DayLayout.minutesPerDay - grid.slotMinutes)
    }

    /// Where a lifted block of `spanMinutes` lands with its top edge at `topY` and its centre at
    /// `centerX`: the nearest column and slot, kept inside the day.
    func dropSlot(topY: CGFloat, centerX: CGFloat, spanMinutes: Int) -> (dayIndex: Int, startMinute: Int) {
        let latest = max(0, DayLayout.minutesPerDay - spanMinutes)
        let minute = min(grid.snappedMinute(forY: Double(topY)), latest)
        return (nearestDayIndex(atX: centerX), minute)
    }
}
