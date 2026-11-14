import SwiftUI

/// One thin line at the bottom: focused pane, the block happening now, pending key sequence,
/// the last message, pending writes, and sync state.
struct StatusBarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(JoyPreference.pendingKeys.key) private var showsPendingKeys = true
    @AppStorage(JoyPreference.currentProgress.key) private var showsCurrent = true

    var body: some View {
        HStack(spacing: 12) {
            Text(model.focus == .tasks ? "Tasks" : "Calendar")
                .foregroundStyle(.secondary)
            if showsCurrent, let current = model.currentBlockText {
                Label(current, systemImage: "timer")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showsPendingKeys, !model.pendingKeys.isEmpty {
                Text(model.pendingKeys)
                    .monospaced()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }
            if let message = model.statusMessage {
                Text(message)
                    .lineLimit(1)
            }
            Spacer()
            #if DEBUG
            HeldKeyDiagnostics(keys: ["x", "z", "c", "/"])
            InteractionModeDiagnostics()
            if UserDefaults.standard.bool(forKey: "demoData"),
               UserDefaults.standard.bool(forKey: "uiHeldKeyDiagnostics") {
                Text(model.eventDetailID ?? "none")
                    .accessibilityIdentifier("interaction-event-target")
                    .accessibilityValue(model.eventDetailID ?? "none")
                Text(model.selection.map { String(describing: $0) } ?? "none")
                    .accessibilityIdentifier("interaction-selection")
                    .accessibilityValue(model.selection.map { String(describing: $0) } ?? "none")
            }
            if let diagnostics = model.editorDiagnostics {
                Text(diagnostics.text)
                    .monospaced()
                    .accessibilityIdentifier("editor-diagnostics")
                    .accessibilityValue(diagnostics.text)
            }
            #endif
            if model.pendingWriteCount > 0 {
                Text("\(model.pendingWriteCount) pending")
                    .foregroundStyle(.secondary)
            }
            SyncStatusLabel()
            Text("? for shortcuts")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(FloridaStyle.paper)
    }
}

/// "Syncing…", "Synced 2:03 PM", "Not synced yet", or the last error in red.
struct SyncStatusLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isSyncing {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Syncing…")
            }
            .foregroundStyle(.secondary)
        } else if let error = model.lastSyncError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(error)
        } else if let at = model.lastSyncAt {
            Text("Synced \(DateText.time(at))")
                .foregroundStyle(.secondary)
        } else if model.syncClient == nil {
            Text("No server")
                .foregroundStyle(.secondary)
        } else {
            Text("Not synced yet")
                .foregroundStyle(.secondary)
        }
    }
}
