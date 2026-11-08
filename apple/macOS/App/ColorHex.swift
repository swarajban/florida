import FloridaKit
import SwiftUI

extension Color {
    /// Parses "#RRGGBB" or "#RGB" (the hash is optional); nil for anything else.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard let value = UInt32(text, radix: 16) else { return nil }
        let red: Double
        let green: Double
        let blue: Double
        switch text.count {
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        case 3:
            red = Double((value >> 8) & 0xF) / 15
            green = Double((value >> 4) & 0xF) / 15
            blue = Double(value & 0xF) / 15
        default:
            return nil
        }
        self.init(red: red, green: green, blue: blue)
    }

    /// Tint for projects without a color: the "#4F46E5" indigo the models document as the default.
    static let defaultProject = Color(hex: "#4F46E5") ?? .indigo
    /// Tint for Google calendars without a color.
    static let defaultCalendar = Color(hex: "#3B82F6") ?? .blue
}

extension Project {
    var tint: Color { color.flatMap(Color.init(hex:)) ?? .defaultProject }
}

extension CalendarInfo {
    var tint: Color { color.flatMap(Color.init(hex:)) ?? .defaultCalendar }
}
