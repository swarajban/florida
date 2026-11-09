import SwiftUI

/// How the Agenda tab lays out the selected day: the timeline list, or a time grid of one or three
/// days. Stored in the App Group defaults under `agenda.mode`.
enum AgendaMode: String, CaseIterable, Identifiable {
    case list
    case day
    case threeDays

    static let storageKey = "agenda.mode"

    var id: Self { self }

    /// Columns the grid shows; nil for the list.
    var dayCount: Int? {
        switch self {
        case .list: nil
        case .day: 1
        case .threeDays: 3
        }
    }

    var title: String {
        switch self {
        case .list: "List"
        case .day: "Day"
        case .threeDays: "3 Days"
        }
    }

    var symbolName: String {
        switch self {
        case .list: "list.bullet"
        case .day: "rectangle.portrait"
        case .threeDays: "rectangle.split.3x1"
        }
    }
}
