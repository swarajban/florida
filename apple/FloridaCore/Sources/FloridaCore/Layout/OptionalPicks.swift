import Foundation

/// What the scheduler suggests for one optional routine block on one day ("Evening, if you're up
/// for it"), joined with the tasks for display. Built from store rows by both apps; no I/O.
public struct OptionalPicks: Hashable, Sendable, Identifiable {
    /// One suggested piece of work.
    public struct Pick: Hashable, Sendable, Identifiable {
        public var placement: OptionalPlacement
        public var task: TaskItem

        public var id: String { placement.id }
        public var minutes: Int { Int(placement.endAt.timeIntervalSince(placement.startAt) / 60) }
    }

    /// The optional `RoutineBlock`'s id.
    public var id: String
    /// The block's name ("Evening"); nil while the routine has not synced.
    public var blockName: String?
    /// By start, then task id. Never empty.
    public var picks: [Pick]

    public var totalMinutes: Int { picks.reduce(0) { $0 + $1.minutes } }

    /// The suggestions that start on the local day containing `day`, one group per block, groups in
    /// order of their first start. Leaves out a suggestion that has ended, and one whose task is
    /// unknown, done, deleted or pinned: pinning is how the user takes a suggestion, so it goes
    /// away at once instead of waiting for the server's next run.
    public static func on(
        day: Date, placements: [OptionalPlacement], tasksById: [String: TaskItem],
        blocksById: [String: RoutineBlock], now: Date, calendar: Calendar
    ) -> [OptionalPicks] {
        var groups: [String: [Pick]] = [:]
        for placement in placements where calendar.isDate(placement.startAt, inSameDayAs: day) && placement.endAt > now {
            guard let task = tasksById[placement.taskId], task.isOpen, task.pinnedStart == nil else { continue }
            groups[placement.blockId, default: []].append(Pick(placement: placement, task: task))
        }
        return groups
            .map { blockId, picks in
                OptionalPicks(
                    id: blockId, blockName: blocksById[blockId]?.name,
                    picks: picks.sorted { ($0.placement.startAt, $0.task.id) < ($1.placement.startAt, $1.task.id) })
            }
            .sorted { ($0.picks[0].placement.startAt, $0.id) < ($1.picks[0].placement.startAt, $1.id) }
    }
}
