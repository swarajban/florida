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

    /// SF Symbol for the quick-add chip of the priority.
    var symbolName: String {
        switch self {
        case .asap, .high: "flag.fill"
        case .medium: "flag"
        case .low: "arrow.down"
        }
    }

    /// What a task row prints for the priority: only the two that ask for attention. Medium and
    /// low say nothing, so an ordinary list is not a column of marks.
    var rowMarker: String? {
        switch self {
        case .asap, .high: displayName
        case .medium, .low: nil
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
