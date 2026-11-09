import FloridaKit
import SwiftUI

/// Settings' view of the sync queue: changes the server refused (retry or dismiss each) and
/// local changes still waiting to be pushed (push now, or discard one).
struct SyncQueueSections: View {
    @Environment(AppModel.self) private var model
    @State private var discarding: PendingWrite?

    var body: some View {
        if !model.rejectedChanges.isEmpty {
            Section {
                ForEach(model.rejectedChanges) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(title(change.entity, change.entityId, change.op), systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text("HTTP \(change.status): \(change.message.isEmpty ? "no reason given" : change.message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack(spacing: 16) {
                            Button("Retry") {
                                model.retry(change)
                            }
                            Button("Dismiss", role: .destructive) {
                                model.dismissRejection(change)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Rejected by the server")
            } footer: {
                Text("The server refused these changes; the app now shows the server's version. Retry sends your version again.")
            }
        }

        Section {
            if model.pendingWrites.isEmpty {
                Label("Everything is synced", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.pendingWrites, id: \.seq) { write in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(write.entity, write.entityId, write.op))
                            Text(write.createdAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            discarding = write
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Discard")
                    }
                    .accessibilityElement(children: .combine)
                }
                Button {
                    model.requestSync()
                } label: {
                    Label("Push now", systemImage: "arrow.up.circle")
                }
                .disabled(model.needsSetup || model.isSyncing)
            }
        } header: {
            Text("Waiting to sync (\(model.pendingWriteCount))")
        }
        .confirmationDialog(
            "Discard this change?",
            isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
            titleVisibility: .visible,
            presenting: discarding
        ) { write in
            Button("Discard", role: .destructive) {
                model.discardPendingWrite(write)
            }
        } message: { _ in
            Text("It will not be sent. This device keeps showing it until the server's copy changes.")
        }
    }

    /// "Save Task “Pay taxes”", "Delete Category “Home”".
    private func title(_ entity: PendingWrite.Entity, _ id: String, _ op: PendingWrite.Op) -> String {
        "\(op == .delete ? "Delete" : "Save") \(model.describeEntity(entity, id: id))"
    }
}
