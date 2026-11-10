import FloridaKit
import SwiftUI

/// Six weeks of day cells listing each day's items as text lines. Click a day to highlight it,
/// click a line to select that item (double-click: edit a task, open an event's details),
/// double-click a day to open it in the day view.
struct MonthGridView: View {
    @Environment(AppModel.self) private var model

    static let maxLinesPerCell = 4

    var body: some View {
        let layout = model.gridLayout
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(layout.days.prefix(7)), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            Divider()
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let index = week * 7 + weekday
                        if layout.days.indices.contains(index) {
                            MonthCellView(dayIndex: index, layout: layout)
                        } else {
                            Color.clear
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
            }
        }
    }
}

/// One day of the month grid.
struct MonthCellView: View {
    @Environment(AppModel.self) private var model
    let dayIndex: Int
    let layout: GridLayout

    var body: some View {
        let day = layout.days[dayIndex]
        let calendar = model.calendar
        let isToday = calendar.isDateInToday(day)
        let isSelectedDay = calendar.isDate(day, inSameDayAs: model.selectedDay)
        let inMonth = calendar.isDate(day, equalTo: model.anchorDate, toGranularity: .month)
        let allDay = layout.allDayByDay[dayIndex]
        let timed = layout.blocksByDay[dayIndex]
        let total = allDay.count + timed.count
        let overflow = max(0, total - MonthGridView.maxLinesPerCell)

        VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.day()))
                .font(.caption.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? FloridaStyle.paper : (inMonth ? FloridaStyle.ink : Color.secondary))
                .frame(width: 20, height: 20)
                .background(isToday ? FloridaStyle.ink : .clear, in: Circle())
            ForEach(allDay.prefix(MonthGridView.maxLinesPerCell)) { block in
                line(item: block.item, day: day, text: block.title, tint: block.tint, filled: true)
            }
            ForEach(timed.prefix(max(0, MonthGridView.maxLinesPerCell - allDay.count))) { block in
                line(item: block.item, day: day, text: "\(DateText.time(block.start)) \(block.title)", tint: block.tint, filled: block.isEvent)
            }
            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isSelectedDay ? FloridaStyle.ink.opacity(0.05) : (inMonth ? Color.clear : Color.primary.opacity(0.02)))
        .overlay(alignment: .trailing) {
            Divider()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.goTo(day: day)
            model.setViewMode(.day)
        }
        .onTapGesture {
            model.focus = .calendar
            model.selectDay(day)
            // The status bar's note was about the line this click deselects.
            model.statusMessage = nil
            model.select(nil)
        }
    }

    private func line(item: ItemID, day: Date, text: String, tint: Color, filled: Bool) -> some View {
        let isSelected = model.selection == item
        // An event spanning several cells shows its detail from the first one.
        let detailId: String? = if case .event(let id) = item, layout.day(of: item) == day { id } else { nil }
        return HStack(spacing: 4) {
            Circle()
                .fill(filled ? tint : .clear)
                .overlay(Circle().strokeBorder(tint, lineWidth: 1))
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(isSelected ? FloridaStyle.ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.select(item, in: .calendar)
            model.editSelection()
        }
        .onTapGesture {
            model.select(item, in: .calendar)
        }
        .eventDetailPopover(model, eventId: detailId)
    }
}
