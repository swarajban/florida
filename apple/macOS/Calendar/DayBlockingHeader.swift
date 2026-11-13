import FloridaKit
import SwiftUI

struct DayBlockingHeader: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        DayBlockingIndicator(
            events: AllDayBlocking.events(on: day, from: model.blockingAllDayEvents, calendar: model.calendar),
            day: day, calendar: model.calendar, compact: true
        ) { event in
            model.eventDetailID = event.id
            model.eventDetailIndicatorDay = day
        }
    }
}
