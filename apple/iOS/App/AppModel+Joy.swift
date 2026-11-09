import FloridaKit
import Foundation

// Local, interruptible delights of the agenda (see `JoySetting`): finished blocks kept as
// ghosts for the day, tasks that fit a free gap, and "Day cleared". Nothing here touches the
// network; every switch is in Settings.

extension AppModel {
    // MARK: - Ghosts

    /// Remembers today's blocks of a task just worked on: those that had started by `now`, or,
    /// with `includeUpcoming` (a completed task), the first one when none had begun. Returns the
    /// ghost ids, which Undo takes back.
    @discardableResult
    func recordGhosts(for task: TaskItem, includeUpcoming: Bool = true, now: Date = Date()) -> [String] {
        guard JoySetting.ghosts.isOn else { return [] }
        let todayRange = today..<(calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400))
        let blocks = (placementsByTask[task.id] ?? [])
            .filter { todayRange.contains($0.startAt) }
            .sorted { $0.startAt < $1.startAt }
        let started = blocks.filter { $0.startAt <= now }
        let finished = started.isEmpty && includeUpcoming ? Array(blocks.prefix(1)) : started
        let known = Set(ghostBlocks.map(\.id))
        let new = finished.filter { !known.contains($0.id) }.map {
            GhostBlock(id: $0.id, taskId: task.id, title: task.title, categoryId: task.categoryId, start: $0.startAt, end: $0.endAt)
        }
        guard !new.isEmpty else { return [] }
        ghostBlocks += new
        GhostStore.save(ghostBlocks, today: today)
        return new.map(\.id)
    }

    func removeGhosts(ids: [String]) {
        guard !ids.isEmpty else { return }
        let drop = Set(ids)
        ghostBlocks.removeAll { drop.contains($0.id) }
        GhostStore.save(ghostBlocks, today: today)
    }

    /// Ghosts to draw on `selectedDay`: today's only, without those whose placement is still live.
    var visibleGhosts: [GhostBlock] {
        guard JoySetting.ghosts.isOn, selectedDay == today else { return [] }
        let live = Set(agenda?.placements.map(\.placement.id) ?? [])
        return ghostBlocks.filter { !live.contains($0.id) }
    }

    /// Called when the local day changes: yesterday's ghosts go.
    func resetDailyState() {
        ghostBlocks = GhostStore.load(today: today, calendar: calendar)
    }

    // MARK: - Free gaps

    /// Up to three open tasks whose remaining work fits in `minutes`, most urgent first; tasks
    /// already pinned, or not allowed to start by `start`, are left out.
    func tasksFitting(minutes: Int, at start: Date) -> [TaskItem] {
        Array(openTasks.lazy.filter { task in
            task.pinnedStart == nil && task.remainingMinutes > 0 && task.remainingMinutes <= minutes
                && (task.startAt.map { $0 <= start } ?? true) && self.blooming[task.id] == nil
        }.prefix(3))
    }

    /// Pins the task at `start` (to the minute), with Undo.
    func pin(_ task: TaskItem, at start: Date) {
        let previous = storedVersion(of: task)
        var updated = previous
        updated.pinnedStart = calendar.dateInterval(of: .minute, for: start)?.start ?? start
        guard write({ try $0.saveTask(updated) }) else { return }
        showToast(Toast(
            message: "Pinned “\(task.title)” at \(Formatting.time(updated.pinnedStart ?? start))",
            systemImage: "pin.fill", style: .info, undo: TaskUndo(from: previous, to: updated)))
    }

    // MARK: - Day cleared

    /// Today had task blocks and every one of them is done: struck through, blooming, or a ghost.
    var isDayCleared: Bool {
        guard JoySetting.dayCleared.isOn, selectedDay == today, let agenda else { return false }
        let open = agenda.placements.filter { $0.task.completedAt == nil && blooming[$0.task.id] == nil }
        let done = agenda.placements.count - open.count + visibleGhosts.count
        return open.isEmpty && done > 0
    }
}
