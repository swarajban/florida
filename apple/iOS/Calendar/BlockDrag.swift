import FloridaKit
import SwiftUI

/// A block lifted by a long press, following the finger in whole slots. Only the slot it is over
/// is stored: a finger moving within a slot changes nothing, so nothing is re-evaluated or redrawn
/// until the block actually jumps. The view turns a `BlockDrag` into a frame with `rect(in:)`.
struct BlockDrag: Equatable {
    let block: DayGridLayout.Block
    /// The block's frame before it was lifted; translations are relative to it.
    let homeRect: CGRect
    var dayIndex: Int
    var startMinute: Int
    /// The instant the block now starts at, and its end keeping the item's real duration.
    var start: Date
    var end: Date
    /// "9:15 AM – 10:15 AM" at the slot; formatted when the slot changes, not on every move.
    var timeText: String

    /// A finger has to travel this far before the block leaves its home slot, so a lift followed
    /// by a release does not snap an off-slot item (9:10) to the nearest boundary.
    static let deadZone: CGFloat = 4

    /// The block as it was lifted, still at home.
    init(block: DayGridLayout.Block, homeRect: CGRect) {
        self.block = block
        self.homeRect = homeRect
        dayIndex = block.dayIndex
        startMinute = block.startMinute
        start = block.start
        end = block.end
        timeText = block.timeText
    }

    /// The block was carried to another time (or day); a drop then writes.
    var hasMoved: Bool { start != block.start }

    /// The lifted block's frame: the full width of the column it is over.
    func rect(in geometry: DayGridGeometry) -> CGRect {
        geometry.rect(
            dayIndex: dayIndex, column: 0, columnCount: 1, startMinute: startMinute,
            endMinute: startMinute + block.spanMinutes)
    }

    /// Moves the block to the slot under the finger. Returns false when it stays where it is, so
    /// the caller can skip the state write.
    mutating func move(by translation: CGSize, geometry: DayGridGeometry, days: [Date], calendar: Calendar) -> Bool {
        if !hasMoved, abs(translation.width) < Self.deadZone, abs(translation.height) < Self.deadZone {
            return false
        }
        let slot = geometry.dropSlot(
            topY: homeRect.minY + translation.height, centerX: homeRect.midX + translation.width,
            spanMinutes: block.spanMinutes)
        let home = geometry.dropSlot(topY: homeRect.minY, centerX: homeRect.midX, spanMinutes: block.spanMinutes)
        if slot.dayIndex == home.dayIndex, slot.startMinute == home.startMinute {
            // Carried away and back over its own slot: the item keeps its real start (9:10 stays
            // 9:10 rather than snapping to 9:15), and a drop writes nothing.
            guard hasMoved else { return false }
            dayIndex = block.dayIndex
            startMinute = block.startMinute
            start = block.start
            end = block.end
            timeText = block.timeText
            return true
        }
        guard slot.dayIndex != dayIndex || slot.startMinute != startMinute, days.indices.contains(slot.dayIndex) else {
            return false
        }
        dayIndex = slot.dayIndex
        startMinute = slot.startMinute
        start = DayGridLayout.date(forMinute: startMinute, on: days[dayIndex], calendar: calendar)
        end = start.addingTimeInterval(block.end.timeIntervalSince(block.start))
        timeText = Formatting.timeRange(start, end)
        return true
    }
}
