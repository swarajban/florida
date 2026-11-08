import FloridaKit
import SwiftUI

extension Priority {
    var displayName: String {
        switch self {
        case .asap: "ASAP"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

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
        case .medium: .secondary
        case .low: .secondary
        }
    }
}

extension DeadlineType {
    var displayName: String {
        switch self {
        case .hard: "Hard"
        case .soft: "Soft"
        case .none: "None"
        }
    }
}

extension CalendarViewMode {
    var displayName: String {
        switch self {
        case .day: "Day"
        case .threeDays: "3 Days"
        case .week: "Week"
        case .month: "Month"
        }
    }
}
