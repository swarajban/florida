import FloridaKit
import Foundation

extension AppModel {
    var today: Date { calendar.startOfDay(for: Date()) }

    var visibleRange: Range<Date> {
        DateNavigation.visibleRange(for: viewMode, anchor: anchorDate, calendar: calendar)
    }

    var visibleDays: [Date] {
        DateNavigation.days(in: visibleRange, calendar: calendar)
    }

    /// Switches views around the highlighted day.
    func setViewMode(_ mode: CalendarViewMode) {
        viewMode = mode
        anchorDate = selectedDay
        rangeDidChange()
    }

    /// Moves the day cursor. The view follows when the cursor leaves it; the 3-day view pages by
    /// three days so the cursor lands on the first or last column instead of re-anchoring.
    func moveDay(by days: Int) {
        selectedDay = DateNavigation.shift(selectedDay, by: days, calendar: calendar)
        if !visibleRange.contains(selectedDay) {
            if viewMode == .threeDays {
                anchorDate = DateNavigation.shift(anchorDate, by: days < 0 ? -3 : 3, calendar: calendar)
            }
            if !visibleRange.contains(selectedDay) {
                anchorDate = selectedDay
            }
        }
        rangeDidChange()
    }

    /// Moves by whole weeks, or by whole months in the month view.
    func moveWeek(by weeks: Int) {
        if viewMode == .month {
            selectedDay = calendar.date(byAdding: .month, value: weeks, to: selectedDay) ?? selectedDay
        } else {
            selectedDay = DateNavigation.shift(selectedDay, by: 7 * weeks, calendar: calendar)
        }
        anchorDate = selectedDay
        rangeDidChange()
    }

    /// The header's arrows: one view-width forward or back.
    func page(by direction: Int) {
        switch viewMode {
        case .day: moveDay(by: direction)
        case .threeDays: moveDay(by: 3 * direction)
        case .week, .month: moveWeek(by: direction)
        }
    }

    /// "Sunday, November 8, 2026", "Nov 8 – 14, 2026", or "November 2026".
    var viewTitle: String {
        switch viewMode {
        case .day: DateText.longDay(anchorDate)
        case .threeDays, .week: DateText.rangeTitle(visibleRange, calendar: calendar)
        case .month: DateText.monthTitle(anchorDate)
        }
    }

    /// Jumps the view and the cursor to the day containing `day`.
    func goTo(day: Date) {
        selectedDay = calendar.startOfDay(for: day)
        anchorDate = selectedDay
        rangeDidChange()
    }

    func goToToday() {
        goTo(day: Date())
    }

    /// Highlights a day without moving the view when it is already visible.
    func selectDay(_ day: Date) {
        selectedDay = calendar.startOfDay(for: day)
        if !visibleRange.contains(selectedDay) {
            anchorDate = selectedDay
            rangeDidChange()
        }
    }
}
