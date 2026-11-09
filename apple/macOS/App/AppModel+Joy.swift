import FloridaKit
import Foundation

// The local-only touches: centering on now, jumping to the ends, sliding blocks when the
// scheduler moves them, the current block in the status bar, and filling a free gap.

extension AppModel {
    /// The schedules the categories use (all of them before categories sync), for dimming
    /// off-hours and finding free gaps.
    var activeSchedules: [Schedule] {
        let used = Set(categories.map(\.scheduleId))
        let active = schedules.filter { used.contains($0.id) }
        return active.isEmpty ? schedules : active
    }

    var layoutOptions: GridLayout.Options {
        GridLayout.Options(
            dimsOffHours: JoyPreferences.isOn(.offHours), freeGaps: JoyPreferences.isOn(.freeGaps),
            accountRims: JoyPreferences.isOn(.accountRims))
    }

    func minuteOfDay(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// `zz`: centers the grid on the current time, going to today first when it is not visible.
    func centerOnNow() {
        guard viewMode != .month, visibleRange.contains(Date()) else {
            goToToday()
            return
        }
        gridScrollRequest = GridScrollRequest(minute: minuteOfDay(Date()), centered: true, animated: true)
    }

    /// `gg` / `G`: the first or last item of the focused pane.
    func jumpToEdge(last: Bool) {
        let items = focus == .tasks ? orderedTaskItems : gridLayout.orderedItems
        guard let item = last ? items.last : items.first else {
            showGhost("Nothing here")
            return
        }
        select(item)
    }

    /// After new placements: slides task blocks from their old slots and says how many moved.
    /// Tasks the last action wrote are not counted; they were expected to move.
    func placementsDidChange(from before: [String: LayoutTransition.Slot]) {
        guard !before.isEmpty else { return }
        let after = gridLayout.slotFrames
        let changed = before.filter { key, slot in after[key].map { $0 != slot } ?? false }
        guard !changed.isEmpty else { return }
        if JoyPreferences.isOn(.blockSlide) {
            let transition = LayoutTransition(from: before, startedAt: Date())
            layoutTransition = transition
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(LayoutTransition.duration + 0.05))
                if self?.layoutTransition == transition {
                    self?.layoutTransition = nil
                }
            }
        }
        let undo = recentUndo
        let actedOn = Set(undo?.restores.map(\.taskId) ?? [])
        let moved = Set(changed.keys.map { String($0.prefix { $0 != "#" }) }).subtracting(actedOn)
        guard !moved.isEmpty else { return }
        let text = "Moved \(moved.count) task\(moved.count == 1 ? "" : "s")"
        // `u` undoes the cause only when the reshuffle followed one of our own writes just now;
        // a later one came from elsewhere (an event moved, the server re-planned).
        let followsOurWrite = undo.map { Date().timeIntervalSince($0.at) < 5 } ?? false
        showGhost(followsOurWrite ? "\(text) · u to undo" : text, for: .seconds(2))
    }

    /// "Review doc · 23m": the task block (else timed meeting) happening now and what is left of it.
    var currentBlockText: String? {
        let now = clockNow
        func left(_ end: Date) -> String {
            DateText.duration(minutes: max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up))))
        }
        if let placement = placements.first(where: { $0.startAt <= now && now < $0.endAt }),
           let task = tasksById[placement.taskId] {
            return "\(Self.shortTitle(task.title)) · \(left(placement.endAt))"
        }
        if let event = todayAgenda?.events.first(where: { event in
            guard !event.allDay, let start = event.startAt, let end = event.endAt else { return false }
            return start <= now && now < end
        }), let end = event.endAt {
            return "\(Self.shortTitle(event.summary ?? "(No title)")) · \(left(end))"
        }
        return nil
    }

    /// Space or Return on a free gap: the tasks that fit in it.
    func openFitPicker(_ gap: GridLayout.Gap) {
        openPalette(mode: .fit(start: gap.start, minutes: gap.minutes))
    }

    /// Open tasks whose remaining time fits in `minutes`, in priority order.
    func tasksThatFit(minutes: Int) -> [TaskItem] {
        openTasks.filter { $0.remainingMinutes > 0 && $0.remainingMinutes <= minutes }
    }

    /// Pins `task` to start at `start` (a picked gap).
    func fill(start: Date, with task: TaskItem) {
        var pinned = task
        pinned.pinnedStart = start
        pinned.startAt = nil
        let when = DateText.dayAndTime(start, calendar: calendar)
        if save(pinned, undoLabel: "Pinned \(Self.quoted(task.title)) to \(when)") {
            selection = .task(task.id)
            showGhost("Pinned to \(when)")
        }
    }
}
