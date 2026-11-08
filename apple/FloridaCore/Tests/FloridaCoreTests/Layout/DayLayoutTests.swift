import Foundation
import Testing
@testable import FloridaCore

@Suite struct DayLayoutTests {
    let calendar = PacificTestCalendar.calendar
    /// Wednesday 2026-11-04, a plain PST day.
    let day = PacificTestCalendar.date(2026, 11, 4)

    func item(_ id: String, _ start: (Int, Int), _ end: (Int, Int), dayOffset: Int = 0, endDayOffset: Int? = nil) -> LayoutItem<String> {
        LayoutItem(
            id: id,
            start: PacificTestCalendar.date(2026, 11, 4 + dayOffset, start.0, start.1),
            end: PacificTestCalendar.date(2026, 11, 4 + (endDayOffset ?? dayOffset), end.0, end.1))
    }

    func frames(_ items: [LayoutItem<String>], day: Date? = nil, minimumMinutes: Int = 15) -> [String: LayoutFrame<String>] {
        let result = DayLayout.layout(items, day: day ?? self.day, calendar: calendar, minimumMinutes: minimumMinutes)
        return Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
    }

    @Test func emptyInputGivesEmptyOutput() {
        #expect(DayLayout.layout([LayoutItem<String>](), day: day, calendar: calendar).isEmpty)
    }

    @Test func nonOverlappingItemsEachGetTheFullWidth() {
        let result = frames([item("a", (9, 0), (10, 0)), item("b", (10, 0), (11, 0)), item("c", (14, 0), (15, 30))])
        #expect(result.count == 3)
        for frame in result.values {
            #expect(frame.column == 0)
            #expect(frame.columnCount == 1)
        }
        #expect(result["a"]?.startMinute == 540)
        #expect(result["a"]?.endMinute == 600)
        #expect(result["c"]?.startMinute == 840)
        #expect(result["c"]?.endMinute == 930)
    }

    @Test func twoOverlappingItemsSplitIntoTwoColumns() {
        let result = frames([item("a", (9, 0), (10, 0)), item("b", (9, 30), (10, 30))])
        #expect(result["a"]?.column == 0)
        #expect(result["b"]?.column == 1)
        #expect(result["a"]?.columnCount == 2)
        #expect(result["b"]?.columnCount == 2)
    }

    @Test func chainedOverlapsShareAClusterAndReuseColumns() {
        // A(9–10:30), B(10–11), C(10:45–12): A and C never overlap but are linked through B.
        let result = frames([item("a", (9, 0), (10, 30)), item("b", (10, 0), (11, 0)), item("c", (10, 45), (12, 0))])
        #expect(result["a"]?.column == 0)
        #expect(result["b"]?.column == 1)
        #expect(result["c"]?.column == 0)
        #expect(result.values.allSatisfy { $0.columnCount == 2 })
    }

    @Test func separateClustersDoNotAffectEachOther() {
        let result = frames([
            item("a", (9, 0), (10, 0)), item("b", (9, 0), (10, 0)), item("c", (9, 0), (10, 0)),
            item("d", (13, 0), (14, 0)),
        ])
        #expect(Set([result["a"]!.column, result["b"]!.column, result["c"]!.column]) == [0, 1, 2])
        #expect(result["a"]?.columnCount == 3)
        #expect(result["d"]?.column == 0)
        #expect(result["d"]?.columnCount == 1)
    }

    @Test func sameStartPutsLongerItemFirst() {
        let result = frames([item("short", (9, 0), (9, 30)), item("long", (9, 0), (11, 0))])
        #expect(result["long"]?.column == 0)
        #expect(result["short"]?.column == 1)
        let ordered = DayLayout.layout([item("short", (9, 0), (9, 30)), item("long", (9, 0), (11, 0))], day: day, calendar: calendar)
        #expect(ordered.map(\.id) == ["long", "short"])
    }

    @Test func outputIsInDrawingOrder() {
        let ordered = DayLayout.layout([item("late", (15, 0), (16, 0)), item("early", (8, 0), (9, 0))], day: day, calendar: calendar)
        #expect(ordered.map(\.id) == ["early", "late"])
    }

    @Test func itemCrossingMidnightIsClampedOnBothDays() {
        // Tue Nov 3 22:00 → Wed Nov 4 02:00.
        let overnight = item("night", (22, 0), (2, 0), dayOffset: -1, endDayOffset: 0)
        let onWednesday = frames([overnight])
        #expect(onWednesday["night"]?.startMinute == 0)
        #expect(onWednesday["night"]?.endMinute == 120)
        let onTuesday = frames([overnight], day: PacificTestCalendar.date(2026, 11, 3))
        #expect(onTuesday["night"]?.startMinute == 1320)
        #expect(onTuesday["night"]?.endMinute == 1440)

        // A multi-day item fills the whole day.
        let multiDay = LayoutItem(id: "multi", start: PacificTestCalendar.date(2026, 11, 2, 12), end: PacificTestCalendar.date(2026, 11, 6, 12))
        let result = frames([multiDay])
        #expect(result["multi"]?.startMinute == 0)
        #expect(result["multi"]?.endMinute == 1440)
    }

    @Test func itemsOutsideTheDayAreDropped() {
        let result = frames([
            item("yesterday", (9, 0), (10, 0), dayOffset: -1),
            item("tomorrow", (9, 0), (10, 0), dayOffset: 1),
            // Ends exactly at midnight at the start of the day: not part of it.
            item("endsAtMidnight", (23, 0), (0, 0), dayOffset: -1, endDayOffset: 0),
            // Starts exactly at midnight at the end of the day: not part of it either.
            item("startsAtNextMidnight", (0, 0), (1, 0), dayOffset: 1),
            item("kept", (9, 0), (10, 0)),
        ])
        #expect(result.keys.sorted() == ["kept"])
    }

    @Test func shortItemsAreTreatedAsMinimumLength() {
        // A 5-minute item at 9:00 occupies 9:00–9:15 and therefore overlaps 9:10–9:30.
        let result = frames([item("tiny", (9, 0), (9, 5)), item("next", (9, 10), (9, 30))])
        #expect(result["tiny"]?.startMinute == 540)
        #expect(result["tiny"]?.endMinute == 555)
        #expect(result["tiny"]?.durationMinutes == 15)
        #expect(result["tiny"]?.column == 0)
        #expect(result["next"]?.column == 1)
        #expect(result.values.allSatisfy { $0.columnCount == 2 })

        // With the minimum disabled, the same pair does not overlap.
        let raw = frames([item("tiny", (9, 0), (9, 5)), item("next", (9, 10), (9, 30))], minimumMinutes: 0)
        #expect(raw["tiny"]?.endMinute == 545)
        #expect(raw.values.allSatisfy { $0.columnCount == 1 })

        // A zero-length item is still drawn.
        let zero = frames([item("zero", (9, 0), (9, 0))])
        #expect(zero["zero"]?.startMinute == 540)
        #expect(zero["zero"]?.endMinute == 555)
    }

    @Test func minimumLengthNearMidnightShiftsStartUp() {
        let result = frames([item("late", (23, 55), (23, 58))])
        #expect(result["late"]?.startMinute == 1425)
        #expect(result["late"]?.endMinute == 1440)
    }

    @Test func minutesAreWallClockOnDSTDay() {
        // Sunday 2026-11-01: clocks fall back at 02:00, so 09:00 is 10 elapsed hours after midnight
        // but must still sit on the 9:00 line.
        let dst = PacificTestCalendar.date(2026, 11, 1)
        let nine = PacificTestCalendar.date(2026, 11, 1, 9)
        #expect(nine.timeIntervalSince(dst) == 10 * 3600)
        let result = frames([LayoutItem(id: "meeting", start: nine, end: PacificTestCalendar.date(2026, 11, 1, 10))], day: dst)
        #expect(result["meeting"]?.startMinute == 540)
        #expect(result["meeting"]?.endMinute == 600)
    }

    @Test func dayParameterIsNormalizedToMidnight() {
        let result = frames([item("a", (9, 0), (10, 0))], day: PacificTestCalendar.date(2026, 11, 4, 17, 45))
        #expect(result["a"]?.startMinute == 540)
    }

    @Test func worksWithNonStringIdentifiers() {
        let items = [LayoutItem(id: 1, start: PacificTestCalendar.date(2026, 11, 4, 9), end: PacificTestCalendar.date(2026, 11, 4, 10))]
        let result = DayLayout.layout(items, day: day, calendar: calendar)
        #expect(result.first?.id == 1)
    }
}
