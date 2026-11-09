import FloridaKit
import Foundation

/// What a task row says about when the task will happen, from the scheduler's placements and its
/// `UnscheduledTask` entry:
/// - overdue: the due date has passed and nothing is placed;
/// - late: the last block ends after the due date (the ETA is that block's end);
/// - unscheduled: nothing is placed, with the scheduler's reason when it gave one;
/// - scheduled: placed, possibly only in part (`unplacedMinutes` then says how much is left out).
struct TaskScheduleSummary: Hashable {
    enum State: Hashable {
        case scheduled
        case late(eta: Date)
        case unscheduled
        case overdue(dueAt: Date)
    }

    var state: State
    var firstStart: Date?
    var blockCount: Int
    /// The scheduler's reason code for what it could not place, and how many minutes that is.
    var unplacedReason: String?
    var unplacedMinutes = 0

    init(task: TaskItem, placements: [Placement], unscheduled: UnscheduledTask?, now: Date) {
        let sorted = placements.sorted { $0.startAt < $1.startAt }
        blockCount = sorted.count
        firstStart = sorted.first?.startAt
        if let unscheduled, unscheduled.unplacedMinutes > 0 {
            unplacedReason = unscheduled.reason
            unplacedMinutes = unscheduled.unplacedMinutes
        }
        let lastEnd = sorted.map(\.endAt).max()
        if let dueAt = task.dueAt, let lastEnd, lastEnd > dueAt {
            state = .late(eta: lastEnd)
        } else if let dueAt = task.dueAt, sorted.isEmpty, dueAt <= now {
            state = .overdue(dueAt: dueAt)
        } else if sorted.isEmpty {
            state = .unscheduled
        } else {
            state = .scheduled
        }
    }

    /// Red in the row: the task will miss, or has missed, its due date.
    var isAlarming: Bool {
        switch state {
        case .late, .overdue: true
        case .scheduled, .unscheduled: false
        }
    }

    var symbolName: String {
        switch state {
        case .scheduled: "calendar.badge.clock"
        case .late: "exclamationmark.circle.fill"
        case .unscheduled: "calendar.badge.minus"
        case .overdue: "clock.badge.exclamationmark"
        }
    }

    /// "Today 3:00 PM · 2 blocks", "Late · ETA Fri 3:00 PM", "Overdue · was due Mon 5:00 PM",
    /// "Unscheduled".
    func headline(now: Date, calendar: Calendar) -> String {
        switch state {
        case .scheduled:
            var text = firstStart.map { Formatting.dayAndTime($0, now: now, calendar: calendar) } ?? ""
            if blockCount > 1 {
                text += " · \(blockCount) blocks"
            }
            return text
        case .late(let eta):
            return "Late · ETA \(Formatting.dayAndTime(eta, now: now, calendar: calendar))"
        case .unscheduled:
            return "Unscheduled"
        case .overdue(let dueAt):
            return "Overdue · was due \(Formatting.dayAndTime(dueAt, now: now, calendar: calendar))"
        }
    }

    /// Why some or all of the task is not on the calendar: "No free time before the hard
    /// deadline · 45m unplaced". Nil when everything is placed or the scheduler gave no reason.
    var detail: String? {
        guard let unplacedReason, unplacedMinutes > 0 else { return nil }
        return "\(Self.describe(reason: unplacedReason)) · \(Formatting.duration(minutes: unplacedMinutes)) unplaced"
    }

    static func describe(reason: String) -> String {
        switch reason {
        case "no_fit_in_horizon": "No free time in the scheduling window"
        case "no_fit_before_hard_deadline": "No free time before the hard deadline"
        case "unknown_schedule": "Its schedule no longer exists"
        default: reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
