import FloridaKit
import Foundation

/// Asks the time grid to scroll so `minute` sits a third of the way down (or centered).
struct GridScrollRequest: Equatable {
    let id = UUID()
    let minute: Int
    let centered: Bool
    let animated: Bool
}

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
        let carried = carriedMinute()
        defer { carrySelection(minute: carried) }
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

    /// Moves the highlighted date by whole weeks, regardless of the view.
    func moveWeek(by weeks: Int) {
        moveAnchor(to: DateNavigation.shift(selectedDay, by: 7 * weeks, calendar: calendar))
    }

    private func moveAnchor(to day: Date) {
        let carried = carriedMinute()
        defer { carrySelection(minute: carried) }
        goTo(day: day)
    }

    /// Where the calendar selection sits on the highlighted day, so a day move can keep it there.
    /// Nil when the selection is not a calendar item there (the task pane keeps its selection).
    private func carriedMinute() -> Int? {
        guard focus == .calendar, let selection else { return nil }
        return gridLayout.startMinute(of: selection, onDay: selectedDay) ?? 0
    }

    /// After a day move: the calendar selection follows the cursor to the item on the new day
    /// nearest the old one's start, or clears, so `j` / `k` continue from the new day.
    private func carrySelection(minute: Int?) {
        guard let minute else { return }
        selection = gridLayout.nearestItem(onDay: selectedDay, toMinute: minute)
    }

    /// The header's arrows: one view-width forward or back.
    func page(by direction: Int) {
        switch viewMode {
        case .day: moveDay(by: direction)
        case .threeDays: moveDay(by: 3 * direction)
        case .week: moveWeek(by: direction)
        case .month: moveAnchor(to: calendar.date(byAdding: .month, value: direction, to: selectedDay) ?? selectedDay)
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

    /// `t`: today, with the grid animating back to the current time.
    func goToToday() {
        goTo(day: Date())
        gridScrollRequest = GridScrollRequest(minute: minuteOfDay(Date()), centered: true, animated: true)
    }

    /// Highlights a day without moving the view when it is already visible.
    func selectDay(_ day: Date) {
        endJump()
        resetKeySequence()
        selectedDay = calendar.startOfDay(for: day)
        if !visibleRange.contains(selectedDay) {
            anchorDate = selectedDay
            rangeDidChange()
        }
    }
}
