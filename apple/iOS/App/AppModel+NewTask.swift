import FloridaKit
import Foundation

// New tasks outside quick add: a blank one for the + button, and one read from text by the
// server's AI (`AIClient.parseTask`). Both open the editor for review; nothing is saved until
// the user taps Add. The local quick-add parser stays the instant default.

extension AppModel {
    /// A blank task for the editor: quick add's 30 minutes, medium priority and Inbox, plus a soft
    /// due date on the default day, since nearly every task gets one (the editor's Due date switch
    /// removes it).
    func newTaskTemplate() -> TaskItem {
        let now = Date()
        return TaskItem(
            id: UUID().uuidString.lowercased(),
            categoryId: inbox?.id ?? categories.first?.id ?? TaskCategory.inboxId,
            title: "", durationMinutes: QuickAddTaskBuilder.defaultDurationMinutes,
            priority: .medium, deadlineType: .soft, dueAt: TaskDay.defaultDue(now: now, calendar: taskListCalendar),
            createdAt: now, updatedAt: now)
    }

    /// Sends `text` to `POST /api/ai/parse-task` and returns the draft as an unsaved task plus
    /// the model's rationale. Throws `LocalWriteError` with a message for the field.
    func parseWithAI(_ text: String) async throws -> TaskEditorRequest {
        guard let aiClient else {
            throw LocalWriteError("Connect to the server in Settings to use AI.")
        }
        let draft: TaskDraft
        do {
            draft = try await aiClient.parseTask(text, timeZone: calendar.timeZone)
        } catch SyncError.http(503, _) {
            throw LocalWriteError("AI is off on the server (no Anthropic API key). Press return to add it as typed.")
        } catch {
            throw LocalWriteError("AI parse failed: \(Self.describe(error))")
        }
        var task = newTaskTemplate()
        task.title = draft.title
        task.notes = draft.notes
        task.durationMinutes = max(1, draft.durationMinutes)
        task.minChunkMinutes = draft.minChunkMinutes
        task.priority = draft.priority
        task.deadlineType = draft.dueAt == nil ? .none : draft.deadlineType
        task.dueAt = draft.dueAt
        task.startAt = draft.startAt
        task.pinnedStart = draft.pinnedStart
        if let id = draft.categoryId, category(id: id) != nil {
            task.categoryId = id
        }
        task = draft.applyingSchedulingContext(to: task, projects: projects)
        return TaskEditorRequest(task: task, isNew: true, rationale: draft.rationale)
    }
}

/// What the task sheet shows: an existing task to edit, or an unsaved one to add (from the +
/// button or an AI parse, whose rationale shows on top).
struct TaskEditorRequest: Identifiable {
    var task: TaskItem
    var isNew: Bool
    var rationale: String?

    var id: String { task.id }
}
