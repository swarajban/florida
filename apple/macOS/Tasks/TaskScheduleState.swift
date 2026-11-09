import FloridaKit
import Foundation

/// What a task row says about when the task happens, derived from the scheduler's placements and
/// its unscheduled report: unscheduled when there are no placements, late when the last block
/// ends after the due date, and why (part of) the task did not fit.
struct TaskScheduleState: Hashable {
    enum Kind: Hashable {
        case unscheduled, scheduled, late
    }

    let kind: Kind
    let firstStart: Date?
    /// When the last block ends: the task's ETA.
    let lastEnd: Date?
    let blockCount: Int
    let isPinned: Bool
    /// Due and already past.
    let isOverdue: Bool
    /// The scheduler's reason code when some minutes could not be placed.
    let unplacedReason: String?
    let unplacedMinutes: Int

    init(task: TaskItem, placements: [Placement], unscheduled: UnscheduledTask?, now: Date = Date()) {
        let sorted = placements.sorted { $0.startAt < $1.startAt }
        blockCount = sorted.count
        firstStart = sorted.first?.startAt
        lastEnd = sorted.last?.endAt
        isPinned = task.pinnedStart != nil
        isOverdue = task.dueAt.map { $0 < now } ?? false
        unplacedReason = unscheduled?.reason
        unplacedMinutes = unscheduled?.unplacedMinutes ?? 0
        if sorted.isEmpty {
            kind = .unscheduled
        } else if let dueAt = task.dueAt, let last = sorted.last, last.endAt > dueAt {
            kind = .late
        } else {
            kind = .scheduled
        }
    }

    /// "Unscheduled", "Today 3:00 PM", "Fri 9:00 AM · 2 blocks".
    func label(calendar: Calendar, now: Date = Date()) -> String {
        guard let firstStart else { return "Unscheduled" }
        var parts = [DateText.dayAndTime(firstStart, calendar: calendar, now: now)]
        if blockCount > 1 {
            parts.append("\(blockCount) blocks")
        }
        return parts.joined(separator: " · ")
    }

    /// The trouble line under a row, or nil when the task is on track: "Overdue", "Late · ETA
    /// Fri 5:30 PM", "No room before the hard deadline · 45m unplaced".
    func problem(calendar: Calendar, now: Date = Date()) -> String? {
        var parts: [String] = []
        if isOverdue {
            parts.append("Overdue")
        } else if kind == .late, let lastEnd {
            parts.append("Late · ETA \(DateText.dayAndTime(lastEnd, calendar: calendar, now: now))")
        }
        if let unplacedReason {
            parts.append(Self.reasonText(unplacedReason))
            if kind != .unscheduled, unplacedMinutes > 0 {
                parts.append("\(DateText.duration(minutes: unplacedMinutes)) unplaced")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func reasonText(_ reason: String) -> String {
        switch reason {
        case "no_fit_in_horizon": "No free time in the scheduling horizon"
        case "no_fit_before_hard_deadline": "No room before the hard deadline"
        case "unknown_schedule": "Its schedule no longer exists"
        case "no_allowed_block": "No routine block allows its context"
        default: reason.replacingOccurrences(of: "_", with: " ")
        }
    }
}
