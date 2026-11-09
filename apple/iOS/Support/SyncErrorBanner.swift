import FloridaKit
import SwiftUI

/// The current store or sync problem as a row at the top of a list, so it shows where the user
/// is looking rather than only as a badge on Settings. Retry syncs again; nothing shows while
/// all is well.
struct SyncErrorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let message = model.storeError ?? model.lastError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.footnote)
                Spacer(minLength: 4)
                if model.storeError == nil {
                    Button("Retry") {
                        model.requestSync()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(model.isSyncing || model.needsSetup)
                }
            }
            .accessibilityElement(children: .combine)
        }
        if !model.rejectedChanges.isEmpty {
            let count = model.rejectedChanges.count
            Label("The server rejected \(count) \(count == 1 ? "change" : "changes"). See Settings.", systemImage: "xmark.octagon")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
