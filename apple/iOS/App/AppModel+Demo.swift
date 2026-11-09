#if DEBUG
import FloridaKit
import Foundation

extension AppModel {
    /// Screenshot runs (`-demoData YES`). The store is the fresh in-memory one `openStore()`
    /// returned; it is seeded here. A placeholder server config keeps the setup prompts away
    /// without touching the keychain, and with no `SyncClient` nothing reaches the network.
    func configureForDemo() {
        serverConfig = ServerConfig(token: "demo")
        lastSyncAt = Date()
        guard let database else { return }
        do {
            try database.apply(DemoData.syncResponse(now: Date(), calendar: calendar))
            // A block finished this morning, as a ghost (not persisted: demo runs are throwaway).
            if let start = calendar.date(bySettingHour: 8, minute: 30, second: 0, of: today) {
                ghostBlocks = [GhostBlock(
                    id: "demo-ghost-oncall", taskId: "demo-task-oncall", title: "Triage on-call alerts",
                    categoryId: "demo-eng", start: start, end: start.addingTimeInterval(30 * 60))]
            }
            // The Settings screenshot shows the sync queue: one change waiting (nothing is ever
            // pushed in demo runs) and one the server refused.
            if LaunchOptions.initialTab == .settings {
                if let task = try database.task(id: "demo-task-roadmap") {
                    try database.requeue(PendingWrite(
                        entity: .task, entityId: task.id, op: .put,
                        body: JSONCoding.encoder.encode(TaskWrite(task)), createdAt: Date()))
                }
                rejectedChanges = [RejectedChange(
                    id: "demo-rejected", entity: .task, entityId: "demo-task-funds", op: .put,
                    status: 400, message: "unknown scheduleId demo-old-hours", at: Date())]
            }
            // No AI in demo runs; one canned suggestion shows the triage chip.
            triageSuggestions["demo-task-dentist"] = TriageSuggestion(
                title: "Book dentist appointment", categoryId: "demo-finance",
                rationale: "A personal errand; Personal Finance is the closest personal category.")
        } catch {
            lastError = "Could not seed the demo data: \(error.localizedDescription)"
        }
    }
}
#endif
