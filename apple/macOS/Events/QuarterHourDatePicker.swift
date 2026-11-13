import SwiftUI

/// Native date entry with quarter-hour time choices. Merely opening an existing off-grid
/// event preserves its exact time; choosing a new time clears seconds and uses a 15-minute slot.
struct QuarterHourDatePicker: View {
    let title: String
    @Binding var date: Date
    var showsTime = true
    @Environment(\.calendar) private var calendar

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                MacDateField(title, date: $date, identifier: "date-\(title)", showsLabel: false)
                    .fixedSize()
                if showsTime {
                    MacChoiceField(
                        "\(title) time", selection: minutes,
                        options: timeChoices,
                        identifier: "time-\(title)", showsLabel: false)
                    .fixedSize()
                }
            }
        }
    }

    private var timeChoices: [MacChoice<Int>] {
        let current = minutes.wrappedValue
        let offGrid = current % 15 != 0 ? [MacChoice(current, date.formatted(timeFormat))] : []
        return offGrid + stride(from: 0, to: 1440, by: 15).map { MacChoice($0, timeLabel($0)) }
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
        return time.formatted(timeFormat)
    }

    private var timeFormat: Date.FormatStyle {
        Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute()
    }
}
