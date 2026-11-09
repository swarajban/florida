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

    /// A stored all-day event (UTC midnights) from `first` up to the exclusive `end` date.
    func stored(_ id: String, _ first: String, _ end: String) -> LayoutItem<String> {
        LayoutItem(id: id, start: JSONCoding.parseInstant(first)!, end: JSONCoding.parseInstant(end)!, allDay: true)
    }

    @Test(arguments: [("pacific", PacificTestCalendar.calendar), ("tokyo", AllDayDateTests.tokyo)])
    func allDayItemsCoverTheirLocalDatesOnly(_ name: String, _ calendar: Calendar) {
        // Mon 2026-11-02 … Sun 2026-11-08 in `calendar`.
        let days = (0..<7).map { AllDayDateTests.local(calendar, 2026, 11, 2 + $0) }
        let items = [
            stored("wed", "2026-11-04T00:00:00Z", "2026-11-05T00:00:00Z"),
            stored("wed-fri", "2026-11-04T00:00:00Z", "2026-11-07T00:00:00Z"),
            stored("mon", "2026-11-02T00:00:00Z", "2026-11-03T00:00:00Z"),
            stored("next-mon", "2026-11-09T00:00:00Z", "2026-11-10T00:00:00Z"),
        ]
        let rows = AllDayLayout.rows(items, days: days, calendar: calendar)
        let byId = Dictionary(uniqueKeysWithValues: rows.flatMap { $0 }.map { ($0.id, $0) })
        #expect(byId["wed"]?.startDayIndex == 2 && byId["wed"]?.endDayIndex == 2)
        #expect(byId["wed-fri"]?.startDayIndex == 2 && byId["wed-fri"]?.endDayIndex == 4)
        #expect(byId["mon"]?.startDayIndex == 0 && byId["mon"]?.endDayIndex == 0)
        #expect(byId["next-mon"] == nil, "the next Monday is outside the week in every zone")
        #expect(rows.count == 2)
    }

    @Test func timedItemStraddlingMidnightCoversBothDays() {
        // Thu 23:00 → Fri 01:00 Pacific; not all-day, so its instants are used as they are.
        let late = LayoutItem(id: "late", start: PacificTestCalendar.date(2026, 11, 5, 23), end: PacificTestCalendar.date(2026, 11, 6, 1))
        let result = spans([late])
        #expect(result["late"]?.startDayIndex == 3)
        #expect(result["late"]?.endDayIndex == 4)
    }

    @Test func dayColumnsEndAtTheNextMidnightWhenDSTSkipsIt() throws {
        // Cuba's DST starts 2026-03-08 at 00:00, so that Sunday begins at 01:00 and is 23 hours long.
        var havana = Calendar(identifier: .gregorian)
        havana.timeZone = TimeZone(identifier: "America/Havana")!
        let days = (8..<15).map { day in
            havana.startOfDay(for: havana.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 12))!)
        }
        try #require(havana.component(.hour, from: days[0]) == 1, "expected the Havana DST change at midnight")
        try #require(days[1].timeIntervalSince(days[0]) == 23 * 3600)

        let items = [
            stored("mon", "2026-03-09T00:00:00Z", "2026-03-10T00:00:00Z"),
            // 00:30–01:00 Monday: the hour that adding 24 h to Sunday's 01:00 start attaches to Sunday.
            LayoutItem(id: "mon-early", start: days[1].addingTimeInterval(30 * 60), end: days[1].addingTimeInterval(60 * 60)),
            LayoutItem(id: "sun-late", start: days[0].addingTimeInterval(21 * 3600), end: days[0].addingTimeInterval(22 * 3600)),
        ]
        let rows = AllDayLayout.rows(items, days: days, calendar: havana)
        let byId = Dictionary(uniqueKeysWithValues: rows.flatMap { $0 }.map { ($0.id, $0) })
        #expect(byId["mon"]?.startDayIndex == 1 && byId["mon"]?.endDayIndex == 1)
        #expect(byId["mon-early"]?.startDayIndex == 1 && byId["mon-early"]?.endDayIndex == 1)
        #expect(byId["sun-late"]?.startDayIndex == 0 && byId["sun-late"]?.endDayIndex == 0)
    }

    @Test func emptyInputsGiveEmptyRows() {
        #expect(AllDayLayout.rows([LayoutItem<String>](), days: week, calendar: calendar).isEmpty)
        #expect(AllDayLayout.rows([item("a", 0, 0)], days: [], calendar: calendar).isEmpty)
    }
}
