import FloridaKit
import SwiftUI

/// A category's header in the Tasks list. Inbox reads as a to-do of its own ("3 to triage" in
/// orange, a tray glyph); an empty category says so, since it has no rows under it.
struct TaskSectionHeader: View {
    let section: TaskSection

    var body: some View {
        HStack(spacing: 6) {
            if section.isInbox {
                Image(systemName: section.tasks.isEmpty ? "tray" : "tray.full.fill")
                    .foregroundStyle(section.tasks.isEmpty ? Color.secondary : Color.orange)
                Text(section.title)
                Spacer()
                Text(section.tasks.isEmpty ? "All triaged" : "\(section.tasks.count) to triage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(section.tasks.isEmpty ? Color.secondary : Color.orange)
                    .textCase(nil)
            } else {
                Circle()
                    .fill(Color.category(section.category))
                    .frame(width: 10, height: 10)
                Text(section.title)
                Spacer()
                if section.tasks.isEmpty {
                    Text("Empty")
                        .textCase(nil)
                } else {
                    Text("\(section.tasks.count)")
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
