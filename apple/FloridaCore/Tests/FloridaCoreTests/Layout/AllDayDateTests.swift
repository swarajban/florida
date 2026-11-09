import Foundation
import Testing
@testable import FloridaCore

/// The server stores an all-day date as UTC midnight of that date. These tests use a zone behind
/// UTC (Pacific, where the stored instant falls on the previous local evening) and one ahead of it
/// (Tokyo, where it falls on the same local morning), because a fix that only works on one side
/// of UTC is the likely mistake.
@Suite struct AllDayDateTests {
    static let tokyo: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    static func local(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static func instant(_ iso: String) -> Date {
        JSONCoding.parseInstant(iso)!
    }

    static let calendars: [(String, Calendar)] = [("pacific", PacificTestCalendar.calendar), ("tokyo", tokyo)]

    @Test(arguments: calendars)
    func storedInstantIsUTCMidnightOfTheLocalDate(_ name: String, _ calendar: Calendar) {
        let expected = Self.instant("2026-11-10T00:00:00Z")
        #expect(AllDayDate.storedInstant(forLocalDay: Self.local(calendar, 2026, 11, 10), calendar: calendar) == expected)
        // Any time of the local day maps to the same date, including late evening, where Pacific
        // is already on the next UTC date and Tokyo still on the previous one in the morning.
        #expect(AllDayDate.storedInstant(forLocalDay: Self.local(calendar, 2026, 11, 10, 23), calendar: calendar) == expected)
        #expect(AllDayDate.storedInstant(forLocalDay: Self.local(calendar, 2026, 11, 10, 1), calendar: calendar) == expected)
    }

    @Test(arguments: calendars)
    func singleDayCoversExactlyThatLocalDay(_ name: String, _ calendar: Calendar) {
        let days = AllDayDate.localDays(
            start: Self.instant("2026-11-10T00:00:00Z"), end: Self.instant("2026-11-11T00:00:00Z"), calendar: calendar)
        #expect(days == Self.local(calendar, 2026, 11, 10)..<Self.local(calendar, 2026, 11, 11))
    }

    @Test(arguments: calendars)
    func multiDayCoversEachLocalDay(_ name: String, _ calendar: Calendar) {
        let days = AllDayDate.localDays(
            start: Self.instant("2026-11-09T00:00:00Z"), end: Self.instant("2026-11-12T00:00:00Z"), calendar: calendar)
        #expect(days == Self.local(calendar, 2026, 11, 9)..<Self.local(calendar, 2026, 11, 12))
    }

    @Test func localDaysAcrossDSTEndIsTwentyFiveHours() {
        // US DST ended Sunday 2026-11-01; that local day is 25 hours long.
        let calendar = PacificTestCalendar.calendar
        let days = AllDayDate.localDays(
            start: Self.instant("2026-11-01T00:00:00Z"), end: Self.instant("2026-11-02T00:00:00Z"), calendar: calendar)
        #expect(days.lowerBound == PacificTestCalendar.date(2026, 11, 1))
        #expect(days.upperBound.timeIntervalSince(days.lowerBound) == 25 * 3600)
    }

    @Test(arguments: calendars)
    func storedRangeSelectsOnlyEventsOnTheLocalDay(_ name: String, _ calendar: Calendar) {
        let day = Self.local(calendar, 2026, 11, 10)..<Self.local(calendar, 2026, 11, 11)
        let stored = AllDayDate.storedRange(overlapping: day, calendar: calendar)
        func overlaps(_ start: String, _ end: String) -> Bool {
            Self.instant(start) < stored.upperBound && Self.instant(end) > stored.lowerBound
        }
        #expect(overlaps("2026-11-10T00:00:00Z", "2026-11-11T00:00:00Z"), "Nov 10")
        #expect(!overlaps("2026-11-09T00:00:00Z", "2026-11-10T00:00:00Z"), "Nov 9")
        #expect(!overlaps("2026-11-11T00:00:00Z", "2026-11-12T00:00:00Z"), "Nov 11")
        #expect(overlaps("2026-11-08T00:00:00Z", "2026-11-12T00:00:00Z"), "Nov 8–11")
    }

    @Test func storedRangeOfAPartialDayIncludesThatWholeDay() {
        // 15:00 Nov 9 → 01:00 Nov 10 local touches both days.
        let calendar = PacificTestCalendar.calendar
        let range = PacificTestCalendar.date(2026, 11, 9, 15)..<PacificTestCalendar.date(2026, 11, 10, 1)
        let stored = AllDayDate.storedRange(overlapping: range, calendar: calendar)
        #expect(stored == Self.instant("2026-11-09T00:00:00Z")..<Self.instant("2026-11-11T00:00:00Z"))
    }
}
