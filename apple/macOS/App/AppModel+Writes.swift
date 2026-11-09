import FloridaKit
import Foundation

// Every write goes to the local store first; the live queries update the views, and a background
// sync pushes the change. Nothing here awaits anything. Each task write runs through
// `recordingUndo`, so `u` can put back the fields it changed.

extension AppModel {
    static let defaultDurationMinutes = 30

    /// Upserts a task locally, remembers the fields it changes for `u`, and syncs in the
    /// background. `undoLabel` is past tense ("Edited “X”"); returns false when the store refused.
    @discardableResult
    func save(_ task: TaskItem, undoLabel: String? = nil) -> Bool {
        guard let database else { return false }
        do {
            try recordingUndo(undoLabel ?? "Edited \(Self.quoted(task.title))", taskId: task.id) {
                try database.saveTask(task)
            }
        } catch {
            statusMessage = "Could not save: \(error.localizedDescription)"
            return false
        }
        scheduleSync()
        return true
    }

    /// `x`: deletes at once; `u` brings the task back.
    func deleteSelection() {
        guard let task = selectedTask else {
            statusMessage = selectedEvent == nil ? "Select a task first" : "Events are managed in Google Calendar"
            return
        }
        guard let database else { return }
        let next = neighbor(of: .task(task.id))
        do {
            try recordingUndo("Deleted \(Self.quoted(task.title))", taskId: task.id) {
                try database.deleteTask(id: task.id)
            }
        } catch {
            statusMessage = "Could not delete: \(error.localizedDescription)"
            return
        }
        selection = next
        showGhost("Deleted \(Self.quoted(task.title)) · u to undo", for: .seconds(3))
        scheduleSync()
    }

    /// Space: marks the selected task done; the live query drops it from the list and the grid.
    /// On a free gap it lists the tasks that fit instead.
    func completeSelection() {
        if case .gap(let id)? = selection, let gap = gridLayout.gap(id: id) {
            openFitPicker(gap)
            return
        }
        guard let task = selectedTask else {
            statusMessage = "Select a task first"
            return
        }
        guard let database else { return }
        let next = neighbor(of: .task(task.id))
        completionFeedback(for: task)
        do {
            try recordingUndo("Completed \(Self.quoted(task.title))", taskId: task.id) {
                try database.completeTask(id: task.id)
            }
        } catch {
            statusMessage = "Could not complete: \(error.localizedDescription)"
            return
        }
        selection = next
        showGhost("Done · u to undo")
        scheduleSync()
    }

    /// `p` fixes the task at its first scheduled start; ⇧P frees it again.
    func pinSelection(_ pinned: Bool) {
        guard var task = selectedTask else {
            statusMessage = "Select a task first"
            return
        }
        if pinned {
            guard let start = placementsByTask[task.id]?.first?.startAt else {
                statusMessage = "This task has no scheduled time to pin"
                return
            }
            task.pinnedStart = start
            if save(task, undoLabel: "Pinned \(Self.quoted(task.title))") {
                showGhost("Pinned to \(DateText.dayAndTime(start, calendar: calendar))")
            }
        } else {
            task.pinnedStart = nil
            if save(task, undoLabel: "Unpinned \(Self.quoted(task.title))") {
                showGhost("Unpinned")
            }
        }
    }

    /// `s`: the task may not start before tomorrow, and a pinned start is released.
    func snoozeSelection() {
        guard var task = selectedTask else {
            statusMessage = "Select a task first"
            return
        }
        let tomorrow = DateNavigation.shift(today, by: 1, calendar: calendar)
        task.startAt = tomorrow
        task.pinnedStart = nil
        if save(task, undoLabel: "Pushed \(Self.quoted(task.title)) to tomorrow") {
            showGhost("Pushed to \(tomorrow.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
        }
    }

    func setPriority(_ priority: Priority) {
        guard var task = selectedTask else {
            statusMessage = "Select a task first"
            return
        }
        task.priority = priority
        if save(task, undoLabel: "Set \(Self.quoted(task.title)) to \(priority.displayName)") {
            showGhost("Priority: \(priority.displayName)")
        }
    }

    /// ⇧N / `>New task`: the full editor on a new task with quick add's defaults (Inbox, 30m,
    /// medium priority). `aiText` is parsed by the AI as the editor opens.
    func openNewTaskEditor(aiText: String? = nil) {
        guard let category = inboxCategory else {
            statusMessage = "No categories yet — sync with the server first"
            return
        }
        let now = Date()
        editorAIText = aiText
        editorTask = TaskItem(
            id: UUID().uuidString.lowercased(), categoryId: category.id, title: "",
            durationMinutes: Self.defaultDurationMinutes, priority: .medium, createdAt: now, updatedAt: now)
    }

    /// Creates a task from quick-add text. Returns false (with a status message) when nothing
    /// could be created: no title, or no category in the store yet.
    @discardableResult
    func createTask(from draft: QuickAddDraft) -> Bool {
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            statusMessage = "Type a title for the task"
            return false
        }
        // An unknown #hint lands in Inbox; the preview says so and offers ⇥ to create it first.
        guard let category = matchCategory(hint: draft.categoryHint) ?? inboxCategory else {
            statusMessage = "No categories yet — sync with the server first"
            return false
        }
        let now = Date()
        let task = TaskItem(
            id: UUID().uuidString.lowercased(),
            categoryId: category.id,
            title: title,
            notes: draft.notes,
            durationMinutes: draft.durationMinutes ?? Self.defaultDurationMinutes,
            priority: draft.priority ?? .medium,
            deadlineType: draft.deadlineType ?? (draft.dueAt == nil ? .none : .soft),
            dueAt: draft.dueAt,
            startAt: draft.startAt,
            pinnedStart: draft.pinnedStart,
            createdAt: now,
            updatedAt: now)
        guard save(task, undoLabel: "Added \(Self.quoted(task.title))") else { return false }
        selection = .task(task.id)
        showGhost("Added to \(category.name)")
        return true
    }

    /// The item to select after `item` disappears: the next one in the focused pane, else the previous.
    func neighbor(of item: ItemID) -> ItemID? {
        let items = focus == .tasks ? orderedTaskItems : gridLayout.orderedItems
        guard let index = items.firstIndex(of: item) else { return nil }
        let remaining = items.filter { $0 != item }
        guard !remaining.isEmpty else { return nil }
        return remaining[min(index, remaining.count - 1)]
    }
}
