import SwiftUI

/// Native date entry with quarter-hour time choices. Merely opening an existing off-grid
/// event preserves its exact time; choosing a new time clears seconds and uses a 15-minute slot.
struct QuarterHourDatePicker: View {
    let title: String
    @Binding var date: Date
    var showsTime = true
    @Environment(\.calendar) private var calendar

    var body: some View {
        HStack {
            DatePicker(title, selection: $date, displayedComponents: .date)
            if showsTime {
                Picker("\(title) time", selection: minutes) {
                    if minutes.wrappedValue % 15 != 0 {
                        Text(date.formatted(.dateTime.hour().minute())).tag(minutes.wrappedValue)
                    }
                    ForEach(Array(stride(from: 0, to: 1440, by: 15)), id: \.self) { minute in
                        Text(timeLabel(minute)).tag(minute)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("time-\(title)")
            }
        }
    }

    private var minutes: Binding<Int> {
        Binding(
            get: { calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date) },
            set: { minute in
                date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date) ?? date
            })
    }

    private func timeLabel(_ minute: Int) -> String {
        // A fixed ordinary day avoids missing/repeated clock labels on DST transition days.
        let reference = calendar.date(from: DateComponents(year: 2001, month: 1, day: 15))!
        let time = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: reference)!
        return time.formatted(.dateTime.hour().minute())
    }
}
