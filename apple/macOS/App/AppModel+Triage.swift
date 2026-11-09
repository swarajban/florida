import FloridaKit
import Foundation

// Moving tasks between categories, and the background AI suggestions for Inbox tasks. A
// suggestion is fetched once per task title, one request at a time, and never blocks the pane:
// rows show it when it arrives and ⇥ accepts it.

extension AppModel {
    /// Moves a task to another category (undoable).
    func move(_ task: TaskItem, to category: TaskCategory) {
        guard task.categoryId != category.id else {
            showGhost("Already in \(category.name)")
            return
        }
        var moved = task
        moved.categoryId = category.id
        lastAction = .move(categoryId: category.id)
        if save(moved, undoLabel: "Moved \(Self.quoted(task.title)) to \(category.name)") {
            aiSuggestions[task.id] = nil
            showGhost("Moved to \(category.name)")
        }
    }

    /// `m`: the Move to… picker for the selected task.
    func openMovePicker() {
        guard let task = selectedTask else {
            statusMessage = "Select a task first"
            return
        }
        openPalette(mode: .move(taskId: task.id))
    }

    /// The suggestion worth showing for a task: a live category other than Inbox and its own.
    func suggestedCategory(for task: TaskItem) -> TaskCategory? {
        guard let id = aiSuggestions[task.id]?.categoryId, id != task.categoryId,
              let category = categoriesById[id], !category.isInbox
        else { return nil }
        return category
    }

    /// ⇥: moves the selected Inbox task to its suggested category.
    func acceptSuggestion() {
        guard let task = selectedTask else {
            statusMessage = "Select an Inbox task first"
            return
        }
        guard let category = suggestedCategory(for: task) else {
            showGhost(aiSuggestions[task.id] == nil ? "No suggestion yet" : "No better category than Inbox")
            return
        }
        move(task, to: category)
    }

    /// ⇥ in quick add with an unknown `#hint`: creates the category so the draft lands in it.
    func createCategoryFromHint() {
        guard let hint = palette.draft.categoryHint, matchCategory(hint: hint) == nil else { return }
        createCategory(name: Self.categoryName(fromHint: hint))
        paletteTextDidChange()
    }

    /// Asks the server's AI for the next Inbox task that has no suggestion for its current
    /// title. Runs one request at a time and stops for the session when AI is unavailable.
    func refreshSuggestions() {
        guard let client = aiClient, !isAIUnavailable, suggestionWorker == nil else { return }
        guard let task = openTasks.first(where: { task in
            categoriesById[task.categoryId]?.isInbox == true && suggestionRequests[task.id] != task.title
        }) else { return }
        suggestionRequests[task.id] = task.title
        suggestionWorker = Task { [weak self] in
            var suggestion: CategorySuggestion?
            var unavailable = false
            do {
                suggestion = try await client.suggestCategory(title: task.title, notes: task.notes)
            } catch SyncError.http(let status, _) where status == 503 || status == 404 {
                unavailable = true
            } catch SyncError.unauthorized {
                unavailable = true
            } catch {
                // Offline or a server hiccup: forget the request; the next data change retries it.
                // A cancelled worker (new server settings) leaves the new worker's state alone.
                guard !Task.isCancelled else { return }
                self?.suggestionRequests[task.id] = nil
                self?.suggestionWorker = nil
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.suggestionWorker = nil
            self.isAIUnavailable = unavailable
            if let suggestion {
                self.aiSuggestions[task.id] = suggestion
            }
            self.refreshSuggestions()
        }
    }
}
