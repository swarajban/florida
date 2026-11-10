import Foundation
import Testing
@testable import FloridaCore

/// Pacific is behind UTC, so a local evening is already the next UTC date: a helper that reads the
/// clock or the day in UTC gives a different answer on every case here.
@Suite struct TaskDayTests {
    static let calendar = PacificTestCalendar.calendar

    static func instant(_ iso: String) -> Date {
        JSONCoding.parseInstant(iso)!
    }

    @Test func dueWithNoTimeIsFiveInTheAfternoonOfThatLocalDay() {
        // Friday Nov 13, 22:30 PST is already Saturday in UTC.
        let lateFriday = PacificTestCalendar.date(2026, 11, 13, 22, 30)
        #expect(TaskDay.due(on: lateFriday, calendar: Self.calendar) == Self.instant("2026-11-14T01:00:00Z"))
        // PDT in July: 17:00 is midnight UTC.
        #expect(TaskDay.due(on: PacificTestCalendar.date(2026, 7, 10, 9), calendar: Self.calendar)
            == Self.instant("2026-07-11T00:00:00Z"))
    }

    @Test func defaultDueIsTheNextWeekdayWithNoTime() {
        // Tuesday Nov 10 → Wednesday Nov 11, 17:00 PST.
        let wednesday = TaskDay.defaultDue(now: PacificTestCalendar.date(2026, 11, 10, 9), calendar: Self.calendar)
        #expect(wednesday == Self.instant("2026-11-12T01:00:00Z"))
        #expect(!TaskDay.dueHasTime(wednesday, calendar: Self.calendar))
        // Thursday 22:30 PST is already Friday in UTC; the next local day is still Friday.
        #expect(TaskDay.defaultDue(now: PacificTestCalendar.date(2026, 11, 12, 22, 30), calendar: Self.calendar)
            == Self.instant("2026-11-14T01:00:00Z"))
        // Friday, Saturday and Sunday all land on Monday Nov 16.
        for day in 13...15 {
            #expect(TaskDay.defaultDue(now: PacificTestCalendar.date(2026, 11, day, 14), calendar: Self.calendar)
                == Self.instant("2026-11-17T01:00:00Z"))
        }
    }

    @Test func dueHasTimeOnlyAwayFromTheWholeDayDefaults() {
        // What quick add and the AI parser store for "by friday".
        #expect(!TaskDay.dueHasTime(Self.instant("2026-11-14T01:00:00Z"), calendar: Self.calendar))
        // What the server stores for a repeating task without a due date: 23:59:59.999 local.
        #expect(!TaskDay.dueHasTime(Self.instant("2026-11-14T07:59:59.999Z"), calendar: Self.calendar))
        #expect(TaskDay.dueHasTime(PacificTestCalendar.date(2026, 11, 13, 15, 0), calendar: Self.calendar))
        #expect(TaskDay.dueHasTime(PacificTestCalendar.date(2026, 11, 13, 17, 30), calendar: Self.calendar))
        // 17:00 UTC is 09:00 in Los Angeles: a real time.
        #expect(TaskDay.dueHasTime(Self.instant("2026-11-13T17:00:00Z"), calendar: Self.calendar))
    }

    @Test func notBeforeWithNoTimeIsTheStartOfThatLocalDay() {
        let lateFriday = PacificTestCalendar.date(2026, 11, 13, 22, 30)
        let start = TaskDay.notBefore(on: lateFriday, calendar: Self.calendar)
        #expect(start == Self.instant("2026-11-13T08:00:00Z"))
        #expect(!TaskDay.notBeforeHasTime(start, calendar: Self.calendar))
        #expect(TaskDay.notBeforeHasTime(lateFriday, calendar: Self.calendar))
        // UTC midnight is 16:00 the day before in Los Angeles: a real time.
        #expect(TaskDay.notBeforeHasTime(Self.instant("2026-11-13T00:00:00Z"), calendar: Self.calendar))
    }
}
