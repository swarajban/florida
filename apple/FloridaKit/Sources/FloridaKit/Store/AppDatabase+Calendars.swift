import Foundation
import GRDB

extension AppDatabase {
    /// Sets a calendar's local `selected` flag so views update before the server confirms the
    /// change. Not queued: the server is told with `SyncClient.setCalendarSelected`, and the next
    /// pull replaces the calendar table with the server's copy either way.
    public func setCalendarSelected(id: String, selected: Bool, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE calendar SET selected = ?, updatedAt = ? WHERE id = ?",
                arguments: [selected, now, id])
        }
    }
}
