import AppKit
import FloridaKit

/// An action `.` can run again on whatever is selected next.
enum RepeatableAction: Equatable {
    case command(AppCommand)
    case move(categoryId: String)
    case doNow
    case doneForNow(minutes: Int)

    /// Delete is left out: the selection moves on after `x`, so `.` would delete the next task.
    static let repeatableCommands: Set<AppCommand> = [
        .complete, .pin, .unpin, .snooze,
        .setPriorityAsap, .setPriorityHigh, .setPriorityMedium, .setPriorityLow,
    ]
}

/// The Done for now sheet: how many minutes of `taskId` were just worked.
struct DoneForNowRequest: Identifiable, Equatable {
    var id: String { taskId }
    let taskId: String
    let title: String
    let defaultMinutes: Int
    let remainingMinutes: Int
}

// The block and task actions: Done (space), Done for now (⇧Space), Do now (n), Push to tomorrow
// (s), Move (m), and `.` to repeat the last one. Each is one local write with an undo entry.

extension AppModel {
    /// `n`: pins the selected task to start now.
    func doNowSelection() {
        guard var task = liveSelectedTask, task.isOpen else {
            statusMessage = "Select a task first"
            return
        }
        let original = task
        let now = calendar.date(bySetting: .second, value: 0, of: Date()) ?? Date()
        task.pinnedStart = now
        task.someday = false
        task.startAt = nil
        lastAction = .doNow
        if save(task, original: original, somedayIntent: false, dateEdits: [.pin], undoLabel: "Pinned \(Self.quoted(task.title)) to now") {
            showGhost("Pinned to \(DateText.dayAndTime(now, calendar: calendar))")
        }
    }

    /// ⇧Space: asks how long was worked, defaulting to the elapsed minutes of the block in
    /// progress, else the next block's length (never more than what is left).
    func doneForNowSelection() {
        guard let task = liveSelectedTask, task.isOpen else {
            statusMessage = "Select a task first"
            return
        }
        let now = Date()
        let blocks = placementsByTask[task.id] ?? []
        let suggested: Int
        if let current = blocks.first(where: { $0.startAt <= now && now < $0.endAt }) {
            suggested = Int(now.timeIntervalSince(current.startAt) / 60)
        } else if let next = blocks.first {
            suggested = Int(next.endAt.timeIntervalSince(next.startAt) / 60)
        } else {
            suggested = Self.defaultDurationMinutes
        }
        doneForNow = DoneForNowRequest(
            taskId: task.id, title: task.title,
            defaultMinutes: min(max(1, suggested), max(1, task.remainingMinutes)),
            remainingMinutes: task.remainingMinutes)
    }

    /// Adds `minutes` to the task's completed minutes; finishing the duration completes it.
    /// A pin in the past is released so the scheduler places what is left.
    func logProgress(taskId: String, minutes: Int) {
        guard var task = try? database?.task(id: taskId), task.isOpen, minutes > 0 else { return }
        let original = task
        let now = Date()
        task.completedMinutes = min(task.durationMinutes, task.completedMinutes + minutes)
        if let pinned = task.pinnedStart, pinned < now {
            task.pinnedStart = nil
        }
        let finished = task.completedMinutes >= task.durationMinutes
        if finished {
            task.completedAt = now
        }
        lastAction = .doneForNow(minutes: minutes)
        let worked = DateText.duration(minutes: minutes)
        if save(task, original: original, undoLabel: "Logged \(worked) on \(Self.quoted(task.title))") {
            if finished {
                completionFeedback(for: task)
                if selection == item(for: task) { selection = neighbor(of: item(for: task)) }
            }
            showGhost(finished ? "Done · z to undo" : "Logged \(worked) · \(DateText.duration(minutes: task.remainingMinutes)) left")
        }
    }

    /// `.`: runs the last action again on the current selection.
    func repeatLastAction() {
        guard let lastAction else {
            showGhost("Nothing to repeat")
            return
        }
        switch lastAction {
        case .command(let command):
            perform(command)
        case .move(let categoryId):
            guard let task = selectedTask else {
                statusMessage = "Select a task first"
                return
            }
            guard let category = categoriesById[categoryId] else { return }
            move(task, to: category)
        case .doNow:
            doNowSelection()
        case .doneForNow(let minutes):
            guard let task = selectedTask else {
                statusMessage = "Select a task first"
                return
            }
            logProgress(taskId: task.id, minutes: minutes)
        }
    }

    /// The moment a task is done: a soft system sound, a trackpad tap, and the row's bloom.
    func completionFeedback(for task: TaskItem) {
        if JoyPreferences.isOn(.completionSound) {
            if let sound = Self.completionSound {
                sound.stop()
                #if DEBUG
                editorDiagnostics?.sounds += 1
                #endif
                sound.play()
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        guard JoyPreferences.isOn(.completionBloom) else { return }
        completingTaskIds.insert(task.id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.completingTaskIds.remove(task.id)
        }
    }

    /// Loaded once so the first completion does not wait on the file.
    static let completionSound: NSSound? = {
        let sound = NSSound(named: "Pop")
        sound?.volume = 0.35
        return sound
    }()
}
