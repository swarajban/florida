import AppKit
import FloridaKit

// Sync never blocks the UI: every entry point here returns at once and the work runs in a Task.
// Syncs start on launch, after every local write, on `changed` server events, every 60 s while
// the app is active, and on ⌘R / "Sync now".

extension AppModel {
    static let periodicSyncInterval: Duration = .seconds(60)

    /// Replaces the sync client and change stream for `config` (nil disconnects) and syncs.
    func applyConfig(_ config: ServerConfig?) {
        self.config = config
        changeStream?.cancel()
        changeStream = nil
        for task in backgroundTasks {
            task.cancel()
        }
        backgroundTasks = []
        suggestionWorker?.cancel()
        suggestionWorker = nil
        suggestionRequests = [:]
        isAIUnavailable = false
        guard let config, let database else {
            syncClient = nil
            aiClient = nil
            return
        }
        syncClient = SyncClient(database: database, config: config)
        aiClient = AIClient(config: config)
        lastSyncError = nil
        scheduleSync()
        startChangeStream(config)
        startPeriodicSync()
        refreshSuggestions()
    }

    /// Saves the server settings to the keychain and reconnects.
    func saveServerConfig(_ config: ServerConfig) throws {
        try tokenStore.save(config)
        applyConfig(config)
    }

    /// Starts a push-then-pull in the background. Overlapping calls queue on the client actor.
    func scheduleSync() {
        guard let client = syncClient else { return }
        Task { [weak self] in
            await self?.runSync(client)
        }
    }

    /// Flips a calendar locally right away, then tells the server; the server's reply (or the
    /// next pull) is authoritative either way.
    func setCalendarSelected(id: String, selected: Bool) {
        guard let database else { return }
        do {
            try database.setCalendarSelected(id: id, selected: selected)
        } catch {
            statusMessage = "Could not update the calendar: \(error.localizedDescription)"
            return
        }
        guard let client = syncClient else { return }
        Task { [weak self] in
            do {
                try await client.setCalendarSelected(id: id, selected: selected)
            } catch {
                self?.lastSyncError = Self.describe(error)
            }
            await self?.runSync(client)
        }
    }

    func setCalendarBlocksScheduling(id: String, blocksScheduling: Bool) {
        guard let database else { return }
        do {
            try database.setCalendarBlocksScheduling(id: id, blocksScheduling: blocksScheduling)
        } catch {
            statusMessage = "Could not update the calendar: \(error.localizedDescription)"
            return
        }
        guard let client = syncClient else { return }
        Task { [weak self] in
            do {
                try await client.setCalendarBlocksScheduling(id: id, blocksScheduling: blocksScheduling)
            } catch {
                self?.lastSyncError = Self.describe(error)
            }
            await self?.runSync(client)
        }
    }

    private func runSync(_ client: SyncClient) async {
        syncsInFlight += 1
        defer { syncsInFlight -= 1 }
        do {
            try await client.sync()
            lastSyncAt = Date()
            let rejected = await client.lastRejectedWrites.count
            lastSyncError = rejected == 0 ? nil : "The server rejected \(rejected) change\(rejected == 1 ? "" : "s")"
        } catch {
            lastSyncError = Self.describe(error)
        }
    }

    private func startChangeStream(_ config: ServerConfig) {
        let stream = ChangeStream(config: config)
        changeStream = stream
        backgroundTasks.append(Task { [weak self] in
            for await event in stream.events {
                guard let self else { return }
                // `connected` also syncs: a reconnect may have missed a notice.
                if event.event == "changed" || event.event == "connected" {
                    self.scheduleSync()
                }
            }
        })
    }

    private func startPeriodicSync() {
        backgroundTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.periodicSyncInterval)
                } catch {
                    return
                }
                guard let self else { return }
                if NSApplication.shared.isActive {
                    self.scheduleSync()
                }
            }
        })
    }

    static func describe(_ error: any Error) -> String {
        guard let syncError = error as? SyncError else {
            return error.localizedDescription
        }
        switch syncError {
        case .unauthorized:
            return "The server rejected the API token — check Settings"
        case .http(let status, _):
            return "Server error \(status)"
        case .transport(let underlying):
            return "Offline: \(underlying.localizedDescription)"
        case .decoding:
            return "Unexpected response from the server"
        }
    }
}
