import FloridaKit
import Foundation

/// An event being dragged in the time grid, and where it would land. The canvas draws its block
/// there, the full width of the day, instead of where the layout has it. After the drop the
/// block stays there until the store's change reaches the layout (`AppModel.rebuildLayout` then
/// ends the drag), so it never flickers back to the old slot.
struct GridDrag: Equatable {
    /// The block as the layout had it when the drag began.
    let block: GridLayout.Block
    /// The event as it was then.
    let event: CalendarEvent
    private(set) var dayIndex: Int
    private(set) var startMinute: Int
    /// Where the event would start and end.
    private(set) var start: Date
    private(set) var end: Date
    /// Released: waiting for a yes to tell the guests, or for the layout to catch up.
    var isDropped = false

    init(block: GridLayout.Block, event: CalendarEvent) {
        self.block = block
        self.event = event
        dayIndex = block.dayIndex
        startMinute = block.startMinute
        start = block.start
        end = block.end
    }

    var durationMinutes: Int {
        block.endMinute - block.startMinute
    }

    var endMinute: Int {
        startMinute + durationMinutes
    }

    var hasMoved: Bool {
        dayIndex != block.dayIndex || startMinute != block.startMinute
    }

    /// True for the dragged block while the layout still has it in its old slot.
    func applies(to other: GridLayout.Block) -> Bool {
        other.id == block.id && other.start == block.start
    }

    /// Puts the block at `minute` in column `dayIndex` of `days`. Back in its own slot it has its
    /// own times again, to the second: an event at 9:05 that is put back stays at 9:05.
    mutating func move(toDay dayIndex: Int, minute: Int, days: [Date], calendar: Calendar) {
        guard days.indices.contains(dayIndex) else { return }
        self.dayIndex = dayIndex
        startMinute = minute
        if hasMoved {
            start = BlockDrag.date(onDay: days[dayIndex], minute: minute, calendar: calendar)
            end = start.addingTimeInterval(block.end.timeIntervalSince(block.start))
        } else {
            start = block.start
            end = block.end
        }
    }
}
