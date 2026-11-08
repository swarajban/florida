import FloridaKit
import Foundation

/// What a task row says about when the task will happen, derived from the scheduler's placements:
/// unscheduled when there are none, late when the last block ends after the due date.
struct TaskScheduleSummary: Hashable {
    enum State: Hashable {
        case unscheduled, scheduled, late
    }

    var state: State
    var firstStart: Date?
    var blockCount: Int

    init(task: TaskItem, placements: [Placement]) {
        let sorted = placements.sorted { $0.startAt < $1.startAt }
        blockCount = sorted.count
        firstStart = sorted.first?.startAt
        if sorted.isEmpty {
            state = .unscheduled
        } else if let dueAt = task.dueAt, let last = sorted.last, last.endAt > dueAt {
            state = .late
        } else {
            state = .scheduled
        }
    }

    /// "Unscheduled", "Today 3:00 PM", "Fri 9:00 AM · 2 blocks".
    func text(now: Date, calendar: Calendar) -> String {
        guard let firstStart else { return "Unscheduled" }
        var text = Formatting.dayAndTime(firstStart, now: now, calendar: calendar)
        if blockCount > 1 {
            text += " · \(blockCount) blocks"
        }
        return text
    }
}
