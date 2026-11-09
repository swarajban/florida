import FloridaKit
import SwiftUI

// Small display helpers for the widget views. The widget target does not share sources with the
// app, so the few it needs are repeated here.

extension Color {
    /// Parses a CSS-style "#RRGGBB" (or "#RGB") string as stored in `TaskCategory.color`; nil for anything else.
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
}

extension WidgetBlock {
    /// Category color for task blocks; a neutral secondary for events and colorless categories.
    var tint: Color {
        switch kind {
        case .event: return .secondary
        case .task: return colorHex.flatMap(Color.init(hex:)) ?? .accentColor
        }
    }
}

extension WidgetTask {
    var tint: Color {
        colorHex.flatMap(Color.init(hex:)) ?? .accentColor
    }
}

extension Priority {
    /// SF Symbol drawn in front of a task title.
    var symbolName: String {
        switch self {
        case .asap: "exclamationmark.3"
        case .high: "exclamationmark.2"
        case .medium: "exclamationmark"
        case .low: "arrow.down"
        }
    }

    var tint: Color {
        switch self {
        case .asap: .red
        case .high: .orange
        case .medium, .low: .secondary
        }
    }
}

/// Switches the app writes to the App Group defaults (`JoySetting` in the app target).
enum WidgetSettings {
    /// "Join countdown on the Lock Screen"; on unless turned off.
    static var joinCountdown: Bool {
        UserDefaults(suiteName: Florida.appGroup)?.object(forKey: "joy.joinCountdownWidget") as? Bool ?? true
    }
}

enum WidgetFormatting {
    /// "Today", "Tomorrow", a weekday name within the coming week, otherwise "Nov 20".
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let distance = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch distance {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return date.formatted(.dateTime.weekday(.abbreviated))
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// What a widget shows when there is nothing to list.
struct WidgetPlaceholder: View {
    let available: Bool
    let emptyText: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: available ? "checkmark.circle" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(available ? emptyText : "Open Florida to sync")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
