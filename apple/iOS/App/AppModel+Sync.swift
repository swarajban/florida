import FloridaKit
import Foundation
import SwiftUI
import WidgetKit

// Background sync. Everything here runs on the main actor; the network work happens inside the
// `SyncClient` actor and only its outcome is written back to the model.

extension AppModel {
    /// Called with the scene phase on launch and on every change: an active app syncs at once and
    /// then every two minutes; leaving the foreground stops the timer.
    func scenePhaseChanged(to phase: ScenePhase) {
        periodicSync?.cancel()
        periodicSync = nil
        guard phase == .active else { return }
        requestSync()
        periodicSync = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { break }
                self?.requestSync()
            }
        }
    }

    /// Starts a push-then-pull in the background. A sync already in flight is asked to run once
    /// more when it finishes, so a burst of local writes costs one extra round trip at most.
    func requestSync() {
        guard syncClient != nil else { return }
        if runningSync != nil {
            syncRequestedAgain = true
            return
        }
        runningSync = Task { [weak self] in
            await self?.runSyncLoop()
        }
    }

    /// `requestSync()` that waits for the round trip; for pull-to-refresh.
    func syncNow() async {
        requestSync()
        await runningSync?.value
    }

    /// `POST /api/schedule/run`, then applies the new placements.
    func runScheduler() {
        runServerAction { try await $0.runScheduler() }
    }

    /// `POST /api/google/sync`: the server refreshes Google calendars and reschedules.
    func refreshGoogleCalendars() {
        runServerAction { try await $0.triggerGoogleSync() }
    }

    /// Shows or hides a Google calendar: flips the local flag at once so the agenda updates, then
    /// `PATCH /api/calendars/:id` and a sync so the server's reschedule comes back. The sync runs
    /// after the PATCH on purpose: a pull that lands first would restore the old flag.
    func setCalendarSelected(id: String, selected: Bool) {
        guard let database else { return }
        do {
            try database.setCalendarSelected(id: id, selected: selected)
        } catch {
            lastError = "Could not update the calendar: \(error.localizedDescription)"
            return
        }
        guard let syncClient else { return }
        Task { [weak self] in
            self?.activeOperations += 1
            defer { self?.activeOperations -= 1 }
            do {
                try await syncClient.setCalendarSelected(id: id, selected: selected)
                self?.lastError = nil
            } catch {
                self?.lastError = Self.describe(error)
            }
            await self?.syncNow()
        }
    }

    /// Stores the server settings in the keychain, swaps the sync client, and syncs.
    func saveServerConfig(_ config: ServerConfig) {
        do {
            try tokenStore.save(config)
        } catch {
            lastError = "Could not save to the keychain: \(error.localizedDescription)"
            return
        }
        serverConfig = config
        if let database {
            syncClient = SyncClient(database: database, config: config)
        }
        lastError = nil
        requestSync()
    }

    // MARK: - Private

    private func runSyncLoop() async {
        activeOperations += 1
        defer {
            activeOperations -= 1
            runningSync = nil
        }
        repeat {
            syncRequestedAgain = false
            await syncOnce()
        } while syncRequestedAgain && !Task.isCancelled
    }

    private func syncOnce() async {
        guard let syncClient else { return }
        do {
            try await syncClient.sync()
            let rejected = await syncClient.lastRejectedWrites
            lastSyncAt = Date()
            if let first = rejected.first {
                let noun = rejected.count == 1 ? "change" : "changes"
                lastError = "The server rejected \(rejected.count) \(noun): \(Self.describe(first.error))"
            } else {
                lastError = nil
            }
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastError = Self.describe(error)
        }
    }

    private func runServerAction(_ action: @escaping @Sendable (SyncClient) async throws -> Void) {
        guard let syncClient else {
            lastError = "Connect to the server in Settings first."
            return
        }
        Task { [weak self] in
            self?.activeOperations += 1
            defer { self?.activeOperations -= 1 }
            do {
                try await action(syncClient)
                self?.lastSyncAt = Date()
                self?.lastError = nil
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                self?.lastError = Self.describe(error)
            }
        }
    }

    /// A one-line explanation of a sync failure for the Settings screen.
    static func describe(_ error: any Error) -> String {
        guard let syncError = error as? SyncError else {
            return error.localizedDescription
        }
        switch syncError {
        case .unauthorized:
            return "The server rejected the API token. Check it in Settings."
        case .http(let status, _):
            return "The server returned HTTP \(status)."
        case .transport(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .decoding:
            return "The server sent a response the app could not read."
        }
    }
}
