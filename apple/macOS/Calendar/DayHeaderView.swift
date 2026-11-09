import FloridaKit
import SwiftUI

/// Weekday and day number above each column; today is filled with ink, the
/// highlighted day is outlined. Click highlights a day, double-click opens it in the day view.
struct DayHeaderView: View {
    @Environment(AppModel.self) private var model
    let gutterWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: gutterWidth, height: 0)
            ForEach(model.gridLayout.days, id: \.self) { day in
                let isToday = model.calendar.isDateInToday(day)
                let isSelected = model.calendar.isDate(day, inSameDayAs: model.selectedDay)
                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(isToday ? FloridaStyle.ink : Color.secondary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.title3.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? FloridaStyle.paper : FloridaStyle.ink)
                        .frame(width: 30, height: 30)
                        .background(isToday ? FloridaStyle.ink : .clear, in: Circle())
                        .overlay(Circle().strokeBorder(FloridaStyle.ink, lineWidth: isSelected && !isToday ? 1.5 : 0))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    model.goTo(day: day)
                    model.setViewMode(.day)
                }
                .onTapGesture {
                    model.selectDay(day)
                }
            }
        }
    }
}
