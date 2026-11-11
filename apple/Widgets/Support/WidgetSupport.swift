import FloridaKit
import SwiftUI

/// Deep links handled by the iOS root view.
enum WidgetLinks {
    static let agenda = URL(string: "florida://agenda")
    static let tasks = URL(string: "florida://tasks")
    static let newTask = URL(string: "florida://tasks/new")!
}

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

/// What a widget shows when there is nothing to list. When the store could not be read it also
/// names the reason in small print, so "no data" and "cannot read" look different on the Home Screen.
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
            if !available, let reason = WidgetStore.unavailableReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
