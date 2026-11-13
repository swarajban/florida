import FloridaKit
import SwiftUI

struct TaskCategoryChip: View {
    let category: TaskCategory

    var body: some View {
        Text(shortName)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 9)
            .foregroundStyle(.primary)
            .overlay(alignment: .leading) {
                Circle().fill(tint).frame(width: 5, height: 5).accessibilityHidden(true)
            }
            .accessibilityLabel("Category: \(category.name)")
            .accessibilityIdentifier("task-category-chip-\(category.id)")
    }

    private var shortName: String {
        guard let area = category.area else { return category.name }
        let prefix = "\(area.displayName) "
        return category.name.lowercased().hasPrefix(prefix.lowercased())
            ? String(category.name.dropFirst(prefix.count)) : category.name
    }

    private var tint: Color {
        #if os(macOS)
        return category.tint
        #else
        return Color.category(category)
        #endif
    }
}
