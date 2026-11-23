#if DEBUG
import FloridaKit
import Foundation

extension AppModel {
    func finishCalendarActivationDemo() {
        guard LaunchOptions.demoData, UserDefaults.standard.bool(forKey: "uiCalendarActivation"), let database else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, var calendars = try? database.calendars() else { return }
            for index in calendars.indices where calendars[index].selected { calendars[index].lastSyncedAt = Date() }
            try? database.apply(SyncResponse(cursor: Date().ISO8601Format(), calendars: calendars))
            self.calendarActivation.reconcile(calendars)
        }
    }

    /// Screenshot runs (`-demoData YES`). The store is the fresh in-memory one `openStore()`
    /// returned; it is seeded here. A placeholder server config keeps the setup prompts away
    /// without touching the keychain, and with no `SyncClient` nothing reaches the network.
    func configureForDemo() {
        serverConfig = ServerConfig(token: "demo")
        lastSyncAt = now
        guard let database else { return }
        do {
            if UserDefaults.standard.bool(forKey: "uiLaterFixture") {
                let url = "https://example.com/blog/a-story"
                let item = LaterItem(id: "test-story", url: url, canonicalUrl: url, title: "A story for Later",
                    site: "example.com", kind: .article, estMinutes: 8, savedAt: now, source: .share, updatedAt: now)
                let start = calendar.startOfDay(for: now).addingTimeInterval(18 * 3600)
                let block = CatchUpBlock(id: "test-catch-up", startAt: start, endAt: start.addingTimeInterval(10 * 60),
                    items: [.init(id: item.id, title: item.title, site: item.site, url: url, estMinutes: 8)])
                try database.apply(SyncResponse(cursor: now.ISO8601Format(), laterItems: [item], catchUpBlocks: [block]))
                return
            }
            try database.apply(DemoData.syncResponse(now: now, calendar: calendar))
            if UserDefaults.standard.bool(forKey: "uiDeepLinkFixture") {
                try database.apply(SyncResponse(cursor: now.ISO8601Format(), tasks: [TaskItem(
                    id: "abcdef01-2345-6789-abcd-ef0123456789", categoryId: TaskCategory.inboxId, title: "Deep link fixture",
                    durationMinutes: 30, priority: .medium, createdAt: now, updatedAt: now)]))
            }
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
