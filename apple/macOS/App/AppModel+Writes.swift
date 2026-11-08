import FloridaKit
import Foundation

// Every write goes to the local store first; the live queries update the views, and a background
// sync pushes the change. Nothing here awaits anything.

extension AppModel {
    static let defaultDurationMinutes = 30

    /// Upserts a task locally and syncs in the background.
    func save(_ task: TaskItem) {
        guard let database else { return }
        do {
            try database.saveTask(task)
        } catch {
            statusMessage = "Could not save: \(error.localizedDescription)"
            return
        }
        scheduleSync()
    }

    func deleteSelection() {
        guard let task = selectedTask else {
            statusMessage = selectedEvent == nil ? "Select a task first" : "Events are managed in Google Calendar"
            return
        }
        guard let database else { return }
        let next = neighbor(of: .task(task.id))
        do {
            try database.deleteTask(id: task.id)
        } catch {
            statusMessage = "Could not delete: \(error.localizedDescription)"
            return
        }
        selection = next
        scheduleSync()
    }

    /// Space: marks the selected task done; the live query drops it from the list and the grid.
    func completeSelection() {
        guard let task = selectedTask else {
            statusMessage = "Select a task first"
            return
        }
        guard let database else { return }
        let next = neighbor(of: .task(task.id))
        do {
            try database.completeTask(id: task.id)
        } catch {
            statusMessage = "Could not complete: \(error.localizedDescription)"
            return
        }
        selection = next
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
        } else {
            task.pinnedStart = nil
        }
        save(task)
    }

    /// `s`: the task may not start before tomorrow, and a pinned start is released.
    func snoozeSelection() {
        guard var task = selectedTask else {
            statusMessage = "Select a task first"
            return
        }
        task.startAt = DateNavigation.shift(today, by: 1, calendar: calendar)
        task.pinnedStart = nil
        save(task)
    }

    func setPriority(_ priority: Priority) {
        guard var task = selectedTask else {
            statusMessage = "Select a task first"
            return
        }
        task.priority = priority
        save(task)
    }

    /// Creates a task from quick-add text. Returns false (with a status message) when nothing
    /// could be created: no title, or no project in the store yet.
    @discardableResult
    func createTask(from draft: QuickAddDraft) -> Bool {
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            statusMessage = "Type a title for the task"
            return false
        }
        guard let project = resolveProject(hint: draft.projectHint) else {
            statusMessage = "No projects yet — sync with the server first"
            return false
        }
        let now = Date()
        let task = TaskItem(
            id: UUID().uuidString.lowercased(),
            projectId: project.id,
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
        save(task)
        selection = .task(task.id)
        return true
    }

    /// Matches a `#hint` to a project name case-insensitively, treating "-" and "_" as spaces:
    /// exact match first, then prefix. Without a hint or a match: the project named "Inbox",
    /// else the first project.
    func resolveProject(hint: String?) -> Project? {
        if let hint {
            let wanted = Self.normalizedProjectName(hint)
            if let exact = projects.first(where: { Self.normalizedProjectName($0.name) == wanted }) {
                return exact
            }
            if let prefix = projects.first(where: { Self.normalizedProjectName($0.name).hasPrefix(wanted) }) {
                return prefix
            }
        }
        return projects.first { $0.name.caseInsensitiveCompare("Inbox") == .orderedSame } ?? projects.first
    }

    static func normalizedProjectName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The item to select after `item` disappears: the next one in the focused pane, else the previous.
    private func neighbor(of item: ItemID) -> ItemID? {
        let items = focus == .tasks ? orderedTaskItems : gridLayout.orderedItems
        guard let index = items.firstIndex(of: item) else { return nil }
        let remaining = items.filter { $0 != item }
        guard !remaining.isEmpty else { return nil }
        return remaining[min(index, remaining.count - 1)]
    }
}
