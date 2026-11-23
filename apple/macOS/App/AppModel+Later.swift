import FloridaKit
import Foundation

extension AppModel {
    func writeLater(_ change: (AppDatabase) throws -> Void) -> String? {
        guard let database else { return "The local store is unavailable." }
        do {
            try change(database)
            scheduleSync()
            return nil
        } catch {
            DiagnosticsRecorder.shared.error("mac.store", "writeLater", error)
            return "Could not update Later: \(error.localizedDescription)"
        }
    }

    #if DEBUG
    static func laterFixture(now: Date, calendar: Calendar) -> SyncResponse {
        let url = "https://example.com/blog/a-story"
        let item = LaterItem(id: "test-story", url: url, canonicalUrl: url, title: "A story for Later",
            site: "example.com", kind: .article, estMinutes: 8, savedAt: now, source: .share, updatedAt: now)
        let secondURL = "https://example.com/blog/another-story"
        let second = LaterItem(id: "test-story-two", url: secondURL, canonicalUrl: secondURL, title: "Another story for Later",
            site: "example.com", kind: .article, estMinutes: 5, savedAt: now, source: .share, updatedAt: now)
        let items = [item, second]
        let start = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now
        let block = CatchUpBlock(id: "test-catch-up", startAt: start, endAt: start.addingTimeInterval(30 * 60),
            items: items.map { .init(id: $0.id, title: $0.title, site: $0.site, url: $0.url, estMinutes: $0.estMinutes ?? 0) })
        return SyncResponse(cursor: now.ISO8601Format(), laterItems: items, catchUpBlocks: [block])
    }
    #endif
}
