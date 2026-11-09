import FloridaKit
import Foundation

// AI triage for Inbox: `AIClient.suggestCategory` runs in the background, one task at a time,
// and its answers become one-tap chips on the rows. Nothing waits on it; a task without an
// answer simply has no chip. Each (task, title) is asked once per launch.

extension AppModel {
    /// Starts fetching suggestions for Inbox tasks that have none for their current title.
    /// Does nothing while a run is going (it picks up new tasks itself) or after the server said
    /// AI is unavailable.
    func requestTriageSuggestions() {
        guard triageRunner == nil, aiClient != nil, triageUnavailable == nil else { return }
        triageRunner = Task { [weak self] in
            await self?.runTriage()
            self?.triageRunner = nil
        }
    }

    /// The suggestion to show on a row: for this title, naming a live category other than Inbox.
    func triageSuggestion(for task: TaskItem) -> (category: TaskCategory, rationale: String)? {
        guard task.categoryId == TaskCategory.inboxId, let suggestion = triageSuggestions[task.id],
              suggestion.title == task.title, let id = suggestion.categoryId, let category = category(id: id),
              !category.isInbox
        else { return nil }
        return (category, suggestion.rationale)
    }

    func dismissTriageSuggestion(for task: TaskItem) {
        triageSuggestions[task.id] = TriageSuggestion(title: task.title, categoryId: nil, rationale: "")
    }

    private func runTriage() async {
        while let task = nextTaskNeedingSuggestion(), let aiClient, !Task.isCancelled {
            let key = Self.attemptKey(task)
            triageAttempted.insert(key)
            do {
                let suggestion = try await aiClient.suggestCategory(title: task.title, notes: task.notes)
                triageSuggestions[task.id] = TriageSuggestion(
                    title: task.title, categoryId: suggestion.categoryId, rationale: suggestion.rationale)
            } catch SyncError.http(503, _) {
                triageUnavailable = "AI suggestions are off: the server has no Anthropic API key."
                return
            } catch SyncError.unauthorized {
                triageUnavailable = "AI suggestions need a valid API token. Check it in Settings."
                return
            } catch SyncError.transport {
                // Offline: forget the attempt so the next request retries it.
                triageAttempted.remove(key)
                return
            } catch {
                continue
            }
        }
    }

    private func nextTaskNeedingSuggestion() -> TaskItem? {
        openTasks.first { task in
            task.categoryId == TaskCategory.inboxId
                && triageSuggestions[task.id]?.title != task.title
                && !triageAttempted.contains(Self.attemptKey(task))
        }
    }

    private static func attemptKey(_ task: TaskItem) -> String {
        "\(task.id)\n\(task.title)"
    }
}
