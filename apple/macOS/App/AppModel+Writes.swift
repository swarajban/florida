import FloridaKit
import Foundation

// Every write goes to the local store first; the live queries update the views, and a background
// sync pushes the change. Nothing here awaits anything. Each task write runs through
// `recordingUndo`, so `z` can put back the fields it changed.

extension AppModel {
    static let defaultDurationMinutes = 30

    /// Upserts a task locally, remembers the fields it changes for `z`, and syncs in the
    /// background. `undoLabel` is past tense ("Edited “X”"); returns false when the store refused.
    @discardableResult
    func save(_ task: TaskItem, original: TaskItem? = nil, undoLabel: String? = nil) -> Bool {
        guard let database else { return false }
        do {
            try recordingUndo(undoLabel ?? "Edited \(Self.quoted(task.title))", taskId: task.id) {
                try database.saveTask(task, original: original)
            }
        } catch {
            statusMessage = "Could not save: \(error.localizedDescription)"
            return false
        }
        scheduleSync()
        return true
    }

    /// `x`: deletes a task at once (`z` brings it back). An event, selected or open in its detail
    /// popover, asks first: nothing undoes an event delete.
    func deleteSelection() {
        if let event = commandEvent {
            confirmDelete(event)
            return
        }
        guard let task = selectedTask else {
            statusMessage = "Select a task or event first"
            return
        }
        if task.recurrence != nil {
            recurringTaskToDelete = task
            return
        }
        deleteTask(task)
    }

    /// Called directly only after confirming a recurring delete's scope.
    func deleteTask(_ task: TaskItem) {
        guard let database else { return }
        let next = neighbor(of: item(for: task))
        do {
            guard let snapshot = try database.deleteTask(id: task.id), snapshot.deletedAt == nil else { return }
            pushUndo(UndoEntry(label: "Deleted \(Self.quoted(snapshot.title))", restores: [.undelete(snapshot)], at: Date()))
        } catch {
            statusMessage = "Could not delete: \(error.localizedDescription)"
            return
        }
        selection = next
        showGhost("Deleted \(Self.quoted(task.title)) · z to undo", for: .seconds(3))
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
        complete(task)
    }

    /// Marks `task` done, with the sound and bloom, an undo entry and the "Done" ghost; when it
    /// was the selection, the selection moves to its neighbor. Also the editor's Mark done.
    @discardableResult
    func complete(_ task: TaskItem, savingEdits: Bool = false, original: TaskItem? = nil) -> Bool {
        guard let database else { return false }
        let item = item(for: task)
        let next = neighbor(of: item)
        do {
            guard let stored = try database.task(id: task.id), stored.isOpen else { return false }
            try recordingUndo("Completed \(Self.quoted(task.title))", taskId: task.id) {
                if savingEdits {
                    var completed = task
                    completed.completedAt = Date()
                    completed.completedMinutes = completed.durationMinutes
                    return try database.saveTask(completed, original: original ?? stored)
                } else {
                    return try database.completeTask(id: task.id)
                }
            }
        } catch {
            statusMessage = "Could not complete: \(error.localizedDescription)"
            return false
        }
        completionFeedback(for: task)
        if selection == item {
            selection = next
        }
        showGhost("Done · z to undo")
        scheduleSync()
        return true
    }

    /// `p` fixes the task at its first scheduled start, or a suggestion where it is drawn (which
    /// takes it); ⇧P frees it again.
    func pinSelection(_ pinned: Bool) {
        if pinned, let pick = selectedSuggestion {
            take(pick)
            return
        }
        guard var task = liveSelectedTask, task.isOpen else {
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
        guard var task = liveSelectedTask, task.isOpen else {
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
        guard var task = liveSelectedTask, task.isOpen else {
            statusMessage = "Select a task first"
            return
        }
        task.priority = priority
        if save(task, undoLabel: "Set \(Self.quoted(task.title)) to \(priority.displayName)") {
            showGhost("Priority: \(priority.displayName)")
        }
    }

    /// ⇧N / `>New task`: the full editor on a new task with quick add's defaults (Inbox, 30m,
    /// medium priority) plus a soft due date on the default day, since nearly every task gets one
    /// (the editor's Due box removes it). `aiText` is parsed by the AI as the editor opens.
    func openNewTaskEditor(aiText: String? = nil, source: TaskSource? = nil, quickAdd: QuickAddDraft? = nil, categoryId: String? = nil) {
        guard let category = inboxCategory else {
            statusMessage = "No categories yet — sync with the server first"
            return
        }
        let now = Date()
        editorAIText = aiText
        editorQuickAddDraft = quickAdd
        editorQuickAddCategoryId = categoryId
        var task = TaskItem(
            id: UUID().uuidString.lowercased(), categoryId: category.id, title: "",
            durationMinutes: Self.defaultDurationMinutes, priority: .medium, deadlineType: .soft,
            dueAt: TaskDay.defaultDue(now: now, calendar: calendar), createdAt: now, updatedAt: now)
        task.source = source
        if let quickAdd {
            task.title = quickAdd.title
            task = quickAdd.applyingExplicitFields(to: task, categoryId: categoryId)
        }
        editorTask = task
    }

    /// Creates a task from quick-add text. Returns false (with a status message) when nothing
    /// could be created: no title, or no category in the store yet.
    @discardableResult
    func createTask(from draft: QuickAddDraft, categoryId: String? = nil) -> Bool {
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            statusMessage = "Type a title for the task"
            return false
        }
        // An unknown #hint lands in Inbox; the preview says so and offers ⇥ to create it first.
        if let categoryId, categoriesById[categoryId] == nil {
            statusMessage = "The chosen category was deleted. Choose a current category."
            return false
        }
        guard let category = QuickAddCompletion.category(explicitID: categoryId, hint: draft.categoryHint, categories: categories) else {
            statusMessage = "No categories yet — sync with the server first"
            return false
        }
        let now = Date()
        var task = TaskItem(
            id: UUID().uuidString.lowercased(),
            categoryId: category.id,
            title: title,
            notes: draft.notes,
            durationMinutes: draft.durationMinutes ?? Self.defaultDurationMinutes,
            priority: draft.priority ?? .medium,
            deadlineType: draft.deadlineType ?? (draft.dueAt == nil ? .none : .soft),
            dueAt: draft.dueAt,
            startAt: draft.startAt,
            context: draft.context ?? .computer,
            pinnedStart: draft.pinnedStart,
            createdAt: now,
            updatedAt: now,
            recurrence: draft.recurrence)
        task.source = draft.source
        if task.recurrence != nil {
            task.prepareToEnableRecurrence()
        }
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
