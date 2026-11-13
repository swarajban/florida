import FloridaKit
import Foundation
import SwiftUI

// Actions on one task, from its row in the Tasks list or its block on the agenda: Done, Done for
// now, Do now, Push to tomorrow (Move to… is in `AppModel+Categories`). Each is one local write
// (well under 100 ms, no network in the way) followed by an Undo toast.

extension AppModel {
    static let bloomDuration: Duration = .milliseconds(150)

    /// Completes the task: one `.success` haptic, the row blooms in its category color for
    /// ~150 ms while it folds away, then Undo (which saves the version from before).
    @discardableResult
    func complete(
        _ task: TaskItem, original: TaskItem? = nil, somedayIntent: Bool? = nil, dateEdits: Set<TaskDateField> = []
    ) -> Bool {
        let index = openTasks.firstIndex { $0.id == task.id }
        let now = Date()
        var mutation: AppDatabase.TaskMutation?
        guard write({ database in
            if let original {
                var draft = task
                draft.completedAt = now
                draft.completedMinutes = draft.durationMinutes
                mutation = try database.saveTask(
                    draft, original: original, somedayIntent: somedayIntent, dateEdits: dateEdits, now: now)
            } else {
                mutation = try database.completeTask(id: task.id, at: now)
            }
        }), let mutation, let previous = mutation.before else { return false }
        let completed = mutation.after
        completionCount += 1
        if let index {
            blooming[task.id] = BloomingTask(task: previous, index: index)
            Task { [weak self] in
                try? await Task.sleep(for: Self.bloomDuration)
                withAnimation(.easeInOut(duration: 0.25)) {
                    self?.blooming[task.id] = nil
                }
            }
        }
        showToast(Toast(
            message: "Completed “\(completed.title)”", systemImage: "checkmark.circle.fill", style: .success,
            undo: TaskUndo(from: previous, to: completed)))
        return true
    }

    /// Credits `minutes` of work without finishing: the rest stays open and the scheduler places
    /// it again. Crediting all that is left completes the task instead.
    func doneForNow(_ task: TaskItem, minutes: Int) {
        let previous = storedVersion(of: task)
        guard minutes < previous.remainingMinutes else {
            complete(task)
            return
        }
        var updated = previous
        updated.completedMinutes += max(0, minutes)
        // A pin fixes the whole remainder at one instant that has now passed; let it float.
        if let pinned = updated.pinnedStart, pinned <= Date() {
            updated.pinnedStart = nil
        }
        var mutation: AppDatabase.TaskMutation?
        guard write({ mutation = try $0.saveTask(updated, original: previous) }),
              let mutation, let before = mutation.before else { return }
        let ghosts = recordGhosts(for: before, includeUpcoming: false)
        showToast(Toast(
            message: "\(Formatting.duration(minutes: minutes)) done · \(Formatting.duration(minutes: updated.remainingMinutes)) left on “\(task.title)”",
            systemImage: "checkmark.circle", style: .success, undo: TaskUndo(from: before, to: mutation.after), ghostIds: ghosts))
    }

    /// Pins the task to start now (to the minute).
    func doNow(_ task: TaskItem) {
        pin(task, at: Date())
    }

    /// Not before tomorrow 00:00 local. A pin would override the earliest start, so it is cleared.
    func pushToTomorrow(_ task: TaskItem) {
        let previous = storedVersion(of: task)
        var updated = previous
        updated.startAt = calendar.date(byAdding: .day, value: 1, to: today)
        updated.pinnedStart = nil
        updated.someday = false
        var mutation: AppDatabase.TaskMutation?
        guard write({ mutation = try $0.saveTask(updated, original: previous, somedayIntent: false, dateEdits: [.start, .pin]) }),
              let mutation, let before = mutation.before else { return }
        refreshTaskDateState(mutation.after)
        showToast(Toast(
            message: "Pushed “\(task.title)” to tomorrow", systemImage: "arrow.turn.down.right", style: .info,
            undo: TaskUndo(from: before, to: mutation.after)))
    }

    /// Minutes "Done for now" proposes: the time since its in-progress block started, else the
    /// last block that ended today, else 30 minutes, never more than what is left.
    func suggestedDoneMinutes(for task: TaskItem, now: Date = Date()) -> Int {
        let blocks = placementsByTask[task.id] ?? []
        let remaining = max(1, task.remainingMinutes)
        if let running = blocks.first(where: { $0.startAt <= now && now < $0.endAt }) {
            return min(remaining, max(5, Int(now.timeIntervalSince(running.startAt) / 60)))
        }
        if let last = blocks.filter({ $0.endAt <= now && $0.endAt >= today }).max(by: { $0.endAt < $1.endAt }) {
            return min(remaining, max(5, Int(last.endAt.timeIntervalSince(last.startAt) / 60)))
        }
        return min(remaining, 30)
    }

    /// `openTasks` with just-completed tasks back at their old index while they bloom.
    var listedOpenTasks: [TaskItem] {
        guard !blooming.isEmpty else { return openTasks }
        var tasks = openTasks.filter { blooming[$0.id] == nil }
        for entry in blooming.values.sorted(by: { $0.index < $1.index }) {
            tasks.insert(entry.task, at: min(entry.index, tasks.count))
        }
        return tasks
    }
}
