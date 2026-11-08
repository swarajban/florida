import FloridaKit
import Foundation

/// What a task row says about when the task happens, derived from the scheduler's placements:
/// unscheduled when there are none, late when the last block ends after the due date.
struct TaskScheduleState: Hashable {
    enum Kind: Hashable {
        case unscheduled, scheduled, late
    }

    let kind: Kind
    let firstStart: Date?
    let blockCount: Int
    let isPinned: Bool

    init(task: TaskItem, placements: [Placement]) {
        let sorted = placements.sorted { $0.startAt < $1.startAt }
        blockCount = sorted.count
        firstStart = sorted.first?.startAt
        isPinned = task.pinnedStart != nil
        if sorted.isEmpty {
            kind = .unscheduled
        } else if let dueAt = task.dueAt, let last = sorted.last, last.endAt > dueAt {
            kind = .late
        } else {
            kind = .scheduled
        }
    }

    /// "Unscheduled", "Today 3:00 PM", "Late · Fri 9:00 AM · 2 blocks".
    func label(calendar: Calendar, now: Date = Date()) -> String {
        guard let firstStart else { return "Unscheduled" }
        var parts = [DateText.dayAndTime(firstStart, calendar: calendar, now: now)]
        if kind == .late {
            parts.insert("Late", at: 0)
        }
        if blockCount > 1 {
            parts.append("\(blockCount) blocks")
        }
        return parts.joined(separator: " · ")
    }
}
