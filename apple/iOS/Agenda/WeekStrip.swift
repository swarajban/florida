import FloridaKit
import SwiftUI

/// Seven day cells for the week containing `selectedDay`. Tap a day to select it; swipe
/// horizontally to move a week.
struct WeekStrip: View {
    let selectedDay: Date
    let today: Date
    let calendar: Calendar
    let onSelect: (Date) -> Void
    let onShiftWeek: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DateNavigation.days(in: selectedDay, calendar: calendar), id: \.self) { day in
                Button {
                    onSelect(day)
                } label: {
                    DayCell(day: day, isSelected: day == selectedDay, isToday: day == today, calendar: calendar)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    onShiftWeek(value.translation.width < 0 ? 1 : -1)
                }
        )
    }
}

/// Weekday initial over the day number; a filled circle marks the selected day and the accent
/// color marks today.
private struct DayCell: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let calendar: Calendar

    var body: some View {
        VStack(spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(calendar.component(.day, from: day))")
                .font(.body.weight(isToday ? .bold : .regular))
                .foregroundStyle(numberStyle)
                .frame(width: 34, height: 34)
                .background {
                    if isSelected {
                        Circle().fill(isToday ? Color.accentColor : Color.primary)
                    }
                }
        }
        .padding(.vertical, 2)
    }

    /// White on the accent circle, the window background on the primary circle, accent for an
    /// unselected today, primary otherwise.
    private var numberStyle: AnyShapeStyle {
        if isSelected {
            return isToday ? AnyShapeStyle(Color.white) : AnyShapeStyle(BackgroundStyle())
        }
        return isToday ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary)
    }
}
