import Foundation
import Testing
@testable import FloridaCore

@Suite struct AllDayLayoutTests {
    let calendar = PacificTestCalendar.calendar
    /// Mon 2026-11-02 … Sun 2026-11-08.
    let week = (0..<7).map { PacificTestCalendar.date(2026, 11, 2 + $0) }

    /// An all-day item covering `firstDay...lastDay` as day offsets from the Monday (end exclusive at midnight).
    func item(_ id: String, _ firstDay: Int, _ lastDay: Int) -> LayoutItem<String> {
        LayoutItem(id: id, start: PacificTestCalendar.date(2026, 11, 2 + firstDay), end: PacificTestCalendar.date(2026, 11, 2 + lastDay + 1))
    }

    func spans(_ items: [LayoutItem<String>]) -> [String: AllDaySpan<String>] {
        let rows = AllDayLayout.rows(items, days: week, calendar: calendar)
        return Dictionary(uniqueKeysWithValues: rows.flatMap { $0 }.map { ($0.id, $0) })
    }

    @Test func packsOverlappingSpansIntoRows() {
        let rows = AllDayLayout.rows([item("a", 0, 2), item("b", 1, 1), item("c", 3, 4)], days: week, calendar: calendar)
        #expect(rows.count == 2)
        #expect(rows[0].map(\.id) == ["a", "c"])
        #expect(rows[1].map(\.id) == ["b"])
        let byId = Dictionary(uniqueKeysWithValues: rows.flatMap { $0 }.map { ($0.id, $0) })
        #expect(byId["a"]?.row == 0)
        #expect(byId["b"]?.row == 1)
        #expect(byId["c"]?.row == 0)
        #expect(byId["a"]?.startDayIndex == 0 && byId["a"]?.endDayIndex == 2)
        #expect(byId["b"]?.startDayIndex == 1 && byId["b"]?.endDayIndex == 1)
        #expect(byId["c"]?.startDayIndex == 3 && byId["c"]?.endDayIndex == 4)
        #expect(byId["a"]?.dayCount == 3)
    }

    @Test func inputOrderDoesNotChangePacking() {
        let result = spans([item("c", 3, 4), item("b", 1, 1), item("a", 0, 2)])
        #expect(result["a"]?.row == 0)
        #expect(result["b"]?.row == 1)
        #expect(result["c"]?.row == 0)
    }

    @Test func longerSpansStartingTheSameDayGoFirst() {
        let result = spans([item("short", 0, 0), item("long", 0, 3), item("other", 1, 1)])
        #expect(result["long"]?.row == 0)
        #expect(result["short"]?.row == 1)
        #expect(result["other"]?.row == 1)
    }

    @Test func singleDayItemsOnDifferentDaysShareARow() {
        let result = spans([item("mon", 0, 0), item("tue", 1, 1), item("sun", 6, 6)])
        #expect(result.values.allSatisfy { $0.row == 0 })
        #expect(result["sun"]?.startDayIndex == 6 && result["sun"]?.endDayIndex == 6)
    }

    @Test func spansBeyondTheWeekAreClamped() {
        let long = LayoutItem(id: "long", start: PacificTestCalendar.date(2026, 10, 30), end: PacificTestCalendar.date(2026, 11, 12))
        let result = spans([long])
        #expect(result["long"]?.startDayIndex == 0)
        #expect(result["long"]?.endDayIndex == 6)
        #expect(result["long"]?.dayCount == 7)
    }

    @Test func itemsOutsideTheWeekAreDropped() {
        let before = LayoutItem(id: "before", start: PacificTestCalendar.date(2026, 10, 26), end: PacificTestCalendar.date(2026, 11, 2))
        let after = LayoutItem(id: "after", start: PacificTestCalendar.date(2026, 11, 9), end: PacificTestCalendar.date(2026, 11, 10))
        let rows = AllDayLayout.rows([before, after, item("kept", 2, 2)], days: week, calendar: calendar)
        #expect(rows.count == 1)
        #expect(rows[0].map(\.id) == ["kept"])
    }

    @Test func timedItemsSpanOnlyTheDaysTheyTouch() {
        // Wed 18:00 → Fri 09:00 touches Wed, Thu, Fri.
        let trip = LayoutItem(id: "trip", start: PacificTestCalendar.date(2026, 11, 4, 18), end: PacificTestCalendar.date(2026, 11, 6, 9))
        let result = spans([trip])
        #expect(result["trip"]?.startDayIndex == 2)
        #expect(result["trip"]?.endDayIndex == 4)
    }

    @Test func zeroLengthItemCoversItsStartDay() {
        let instant = PacificTestCalendar.date(2026, 11, 5)
        let result = spans([LayoutItem(id: "zero", start: instant, end: instant)])
        #expect(result["zero"]?.startDayIndex == 3)
        #expect(result["zero"]?.endDayIndex == 3)
    }

    @Test func emptyInputsGiveEmptyRows() {
        #expect(AllDayLayout.rows([LayoutItem<String>](), days: week, calendar: calendar).isEmpty)
        #expect(AllDayLayout.rows([item("a", 0, 0)], days: [], calendar: calendar).isEmpty)
    }
}
