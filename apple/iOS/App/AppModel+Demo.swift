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
        } catch {
            lastError = "Could not seed the demo data: \(error.localizedDescription)"
        }
    }
}
#endif
