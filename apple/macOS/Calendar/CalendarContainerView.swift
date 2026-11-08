import FloridaKit
import SwiftUI

/// Picks the grid for day / 3-day / week or the month table.
struct CalendarContainerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.viewMode {
        case .month:
            MonthGridView()
        case .day, .threeDays, .week:
            CalendarGridView()
        }
    }
}
