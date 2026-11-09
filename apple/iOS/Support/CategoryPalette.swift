import FloridaKit
import Foundation

/// The colors offered for categories, as the "#RRGGBB" strings `TaskCategory.color` stores, with
/// names for VoiceOver.
enum CategoryPalette {
    static let colors: [(hex: String, name: String)] = [
        ("#4F46E5", "Indigo"), ("#2563EB", "Blue"), ("#0891B2", "Cyan"), ("#059669", "Green"),
        ("#65A30D", "Lime"), ("#CA8A04", "Yellow"), ("#EA580C", "Orange"), ("#DC2626", "Red"),
        ("#DB2777", "Pink"), ("#9333EA", "Purple"), ("#78716C", "Stone"), ("#475569", "Slate"),
    ]

    /// The first palette color no category uses yet, cycling when all are taken.
    static func nextColor(after categories: [TaskCategory]) -> String {
        let used = Set(categories.compactMap { $0.color?.uppercased() })
        return colors.first { !used.contains($0.hex) }?.hex ?? colors[categories.count % colors.count].hex
    }

    /// "personal-finance" → "Personal Finance": a `#hint` as a category name.
    static func name(fromHint hint: String) -> String {
        QuickAddTaskBuilder.normalize(hint)
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
