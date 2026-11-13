import FloridaKit
import SwiftUI

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
                if let category = section.category {
                    Circle()
                        .fill(Color.category(category))
                        .frame(width: 10, height: 10)
                }
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
        .font(.subheadline.weight(.medium))
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("tasks-section-\(section.id)")
    }
}
