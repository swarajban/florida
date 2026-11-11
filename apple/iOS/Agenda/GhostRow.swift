import FloridaKit
import SwiftUI

/// A block finished earlier today, kept as a faint struck-through row.
struct GhostRow: View {
    let ghost: GhostBlock
    let category: TaskCategory?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimeColumn(start: ghost.start, end: ghost.completedAt == nil ? ghost.end : nil)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.category(category).opacity(0.5))
                .frame(width: 3)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.category(category))
                    .accessibilityHidden(true)
                Text(ghost.title)
                    .strikethrough()
            }
            .font(.body)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .opacity(0.6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Done: \(ghost.title)")
        .accessibilityValue(ghost.completedAt.map { "Done at \(Formatting.time($0))" } ?? "")
    }
}
