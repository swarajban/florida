import FloridaKit
import Foundation
import SwiftUI
import WidgetKit

// Background sync. Everything here runs on the main actor; the network work happens inside the
// `SyncClient` actor and only its outcome is written back to the model.

extension AppModel {
    /// Called with the scene phase on launch and on every change. An active app rolls the agenda
    /// to today if the day changed, syncs at once and then every two minutes, listens to the
    /// server's change stream, and watches for midnight; leaving the foreground stops all of it.
    func scenePhaseChanged(to phase: ScenePhase) {
        periodicSync?.cancel()
        periodicSync = nil
        stopChangeStream()
        stopMidnightWatcher()
        sceneIsActive = phase == .active
        guard sceneIsActive else { return }
        database?.refreshExternalChanges()
        anchorToTodayIfDayChanged()
        startMidnightWatcher()
        requestSync()
        startChangeStream()
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

    /// Shows or hides a calendar locally and lets the regular queue push the flag.
    func setCalendarSelected(id: String, selected: Bool) {
        guard let database else { return }
        do {
            try database.setCalendarSelected(id: id, selected: selected)
        } catch {
            lastError = "Could not update the calendar: \(error.localizedDescription)"
            return
        }
        WidgetCenter.shared.reloadAllTimelines()
        requestSync()
    }

    func setCalendarBlocksScheduling(id: String, blocksScheduling: Bool) {
        guard let database else { return }
        do {
            try database.setCalendarBlocksScheduling(id: id, blocksScheduling: blocksScheduling)
        } catch {
            lastError = "Could not update the calendar: \(error.localizedDescription)"
            return
        }
        WidgetCenter.shared.reloadAllTimelines()
        requestSync()
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
        aiClient = AIClient(config: config)
        triageUnavailable = nil
        forgetTriageAttempts()
        lastError = nil
        requestSync()
        if sceneIsActive {
            startChangeStream()
        }
    }

    // MARK: - Private

    /// Opens `GET /api/events` and syncs on every `changed` notice. A `connected` after a
    /// reconnect also syncs, since notices sent while the link was down are lost; the first one
    /// is skipped because becoming active has just requested a sync.
    private func startChangeStream() {
        stopChangeStream()
        guard syncClient != nil, let serverConfig else { return }
        let stream = ChangeStream(config: serverConfig)
        changeStream = stream
        changeListener = Task { [weak self] in
            var connections = 0
            for await event in stream.events {
                switch event.event {
                case "changed":
                    self?.requestSync()
                case "connected":
                    connections += 1
                    if connections > 1 {
                        self?.requestSync()
                    }
                default:
                    break
                }
            }
        }
    }

    private func stopChangeStream() {
        changeStream?.cancel()
        changeStream = nil
        changeListener?.cancel()
        changeListener = nil
    }

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
            lastSyncAt = Date()
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
        // A failed push still pulls and may have refused some writes before it stopped; they are
        // listed in Settings, not folded into `lastError`.
        recordRejections(await syncClient.lastRejectedWrites)
        // A failed push still pulls, so the widgets may have something new either way.
        WidgetCenter.shared.reloadAllTimelines()
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
