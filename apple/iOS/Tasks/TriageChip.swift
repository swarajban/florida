import FloridaKit
import SwiftUI

/// The AI's category suggestion on an Inbox row ("Work?"): one tap moves the task there; a long
/// press shows the model's rationale and lets you dismiss the suggestion.
struct TriageChip: View {
    let category: TaskCategory
    let rationale: String
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onAccept) {
            Text("\(category.name)?")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(Color.category(category))
                .background(Color.category(category).opacity(0.14), in: Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Move to \(category.name)")
        .accessibilityHint(rationale)
        .contextMenu {
            Button(action: onAccept) {
                Label("Move to \(category.name)", systemImage: "folder")
            }
            Button(role: .destructive, action: onDismiss) {
                Label("Dismiss suggestion", systemImage: "xmark")
            }
        } preview: {
            VStack(alignment: .leading, spacing: 6) {
                Label("Suggested: \(category.name)", systemImage: "sparkles")
                    .font(.headline)
                Text(rationale.isEmpty ? "No reason given." : rationale)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 300, alignment: .leading)
        }
    }
}
