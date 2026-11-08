import FloridaKit
import SwiftUI

extension Color {
    /// Parses a CSS-style "#RRGGBB" (or "#RGB") string as stored in `Category.color` and
    /// `CalendarInfo.color`; nil for anything else.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    /// The category's color, or the accent color when it has none or it is malformed.
    static func category(_ category: Category?) -> Color {
        category?.color.flatMap(Color.init(hex:)) ?? .accentColor
    }
}
