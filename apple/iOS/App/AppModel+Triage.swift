import FloridaKit
import Foundation

// AI triage for Inbox: `AIClient.suggestCategory` runs in the background, one task at a time,
// and its answers become one-tap chips on the rows. Nothing waits on it; a task without an
// answer simply has no chip. Each (task, title) is asked once: answered ones are remembered in
// the App Group defaults, so a relaunch does not ask the whole Inbox again.

extension AppModel {
    private static let triageAttemptsKey = "triage.attempted"

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

    /// The (task, title) keys asked in earlier launches.
    static func loadTriageAttempts() -> Set<String> {
        Set(UserDefaults.florida.stringArray(forKey: triageAttemptsKey) ?? [])
    }

    /// Forgets every attempt: a new server has other categories to suggest.
    func forgetTriageAttempts() {
        triageAttempted = []
        UserDefaults.florida.removeObject(forKey: Self.triageAttemptsKey)
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
                triageAttempted.remove(key)
                triageUnavailable = "AI suggestions are off: the server has no Anthropic API key."
                return
            } catch SyncError.http(404, _) {
                triageAttempted.remove(key)
                triageUnavailable = "AI suggestions need a newer server."
                return
            } catch SyncError.unauthorized {
                triageAttempted.remove(key)
                triageUnavailable = "AI suggestions need a valid API token. Check it in Settings."
                return
            } catch SyncError.transport {
                // Offline: forget the attempt so the next request retries it.
                triageAttempted.remove(key)
                return
            } catch SyncError.http(let status, _) where status >= 500 {
                // The server or Claude failed on this one: not asked again this launch, but not
                // remembered either, so the next launch tries once more.
                continue
            } catch {
                // A 4xx or an unreadable answer: asking the same again would not help.
            }
            rememberTriageAttempt(key)
        }
    }

    /// Adds `key` to the remembered attempts, dropping those of tasks no longer in Inbox under
    /// that title, so the list never outgrows the Inbox.
    private func rememberTriageAttempt(_ key: String) {
        let inbox = Set(openTasks.lazy.filter { $0.categoryId == TaskCategory.inboxId }.map { Self.attemptKey($0) })
        let kept = Self.loadTriageAttempts().intersection(inbox).union([key])
        UserDefaults.florida.set(kept.sorted(), forKey: Self.triageAttemptsKey)
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
