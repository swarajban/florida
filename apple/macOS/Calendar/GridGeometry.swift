import FloridaKit
import SwiftUI

/// Points for the time grid: a label gutter on the left, then equal day columns. Shared by the
/// drawing code and the hit test so a click lands on what was drawn.
struct GridGeometry {
    let size: CGSize
    let gutterWidth: CGFloat
    let dayCount: Int
    let grid: TimeGrid

    var columnWidth: CGFloat {
        dayCount > 0 ? max(0, size.width - gutterWidth) / CGFloat(dayCount) : 0
    }

    func x(forDay index: Int) -> CGFloat {
        gutterWidth + CGFloat(index) * columnWidth
    }

    func columnRect(forDay index: Int) -> CGRect {
        CGRect(x: x(forDay: index), y: 0, width: columnWidth, height: grid.dayHeight)
    }

    /// The block's frame, inset a point so neighbours do not touch.
    func rect(for block: GridLayout.Block) -> CGRect {
        let width = columnWidth / CGFloat(max(block.columnCount, 1))
        let x = x(forDay: block.dayIndex) + CGFloat(block.column) * width
        let y = grid.y(forMinute: block.startMinute)
        let height = grid.y(forMinute: block.endMinute) - y
        return CGRect(x: x + 1, y: y + 0.5, width: max(width - 2, 2), height: max(height - 1, 4))
    }

    func dayIndex(atX x: CGFloat) -> Int? {
        guard x >= gutterWidth, columnWidth > 0 else { return nil }
        let index = Int((x - gutterWidth) / columnWidth)
        return index < dayCount ? index : nil
    }

    /// The topmost block under `point`, if any.
    func block(at point: CGPoint, in layout: GridLayout) -> GridLayout.Block? {
        guard let day = dayIndex(atX: point.x), layout.blocksByDay.indices.contains(day) else { return nil }
        return layout.blocksByDay[day].last { rect(for: $0).contains(point) }
    }
}
