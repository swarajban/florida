import FloridaKit
import SwiftUI

/// Day / 3-day / week: headers, the all-day strip, and a scrolling `Canvas` time grid that opens
/// at 07:00. Clicks select; a double-click on a block edits it (tasks) or opens it in Google
/// (events); a double-click on empty grid starts a quick add pinned to that slot.
struct CalendarGridView: View {
    @Environment(AppModel.self) private var model

    static let grid = TimeGrid(hourHeight: 60, slotMinutes: 15)
    static let gutterWidth: CGFloat = 56
    static let initialHour = 7

    var body: some View {
        VStack(spacing: 0) {
            DayHeaderView(gutterWidth: Self.gutterWidth)
            Divider()
            AllDayStripView(gutterWidth: Self.gutterWidth)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Color.clear
                                        .frame(height: Self.grid.hourHeight)
                                        .id(hour)
                                }
                            }
                            TimelineView(.everyMinute) { timeline in
                                TimeGridCanvas(
                                    layout: model.gridLayout, selection: model.selection, selectedDay: model.selectedDay,
                                    now: timeline.date, calendar: model.calendar, grid: Self.grid,
                                    gutterWidth: Self.gutterWidth)
                            }
                            .onTapGesture(count: 2) { point in
                                handleTap(at: point, width: geometry.size.width, isDouble: true)
                            }
                            .onTapGesture { point in
                                handleTap(at: point, width: geometry.size.width, isDouble: false)
                            }
                        }
                    }
                    .frame(height: Self.grid.dayHeight)
                }
                .onAppear {
                    proxy.scrollTo(Self.initialHour, anchor: .top)
                }
            }
        }
    }

    private func handleTap(at point: CGPoint, width: CGFloat, isDouble: Bool) {
        let layout = model.gridLayout
        let geometry = GridGeometry(
            size: CGSize(width: width, height: Self.grid.dayHeight), gutterWidth: Self.gutterWidth,
            dayCount: layout.days.count, grid: Self.grid)
        guard let dayIndex = geometry.dayIndex(atX: point.x) else { return }
        if let block = geometry.block(at: point, in: layout) {
            model.select(block.item, in: .calendar)
            if isDouble {
                model.editSelection()
            }
            return
        }
        let day = layout.days[dayIndex]
        model.focus = .calendar
        model.selectDay(day)
        model.select(nil)
        if isDouble {
            let minute = Self.grid.snappedMinute(forY: point.y)
            model.openQuickAdd(prefill: Self.quickAddPrefix(day: day, minute: minute, calendar: model.calendar))
        }
    }

    /// "11/20/2026 at 2:00pm " — the forms `QuickAddParser` reads as a pinned start.
    static func quickAddPrefix(day: Date, minute: Int, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let hour24 = min(minute / 60, 23)
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let clock = String(format: "%d:%02d%@", hour12, minute % 60, hour24 < 12 ? "am" : "pm")
        return "\(components.month ?? 1)/\(components.day ?? 1)/\(components.year ?? 2000) at \(clock) "
    }
}
