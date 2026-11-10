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

    @Test func dueStandsWhileTheStartIsBeforeIt() {
        let dueFriday = TaskDay.due(on: PacificTestCalendar.date(2026, 11, 13, 9), calendar: Self.calendar)
        // Starting on the due day itself still leaves the day: midnight is before 17:00.
        let friday = TaskDay.notBefore(on: PacificTestCalendar.date(2026, 11, 13, 9), calendar: Self.calendar)
        #expect(TaskDay.due(dueFriday, notBefore: friday, calendar: Self.calendar) == dueFriday)
        // Friday 16:59 PST is Saturday 00:59 UTC, one minute before the deadline.
        #expect(TaskDay.due(dueFriday, notBefore: PacificTestCalendar.date(2026, 11, 13, 16, 59), calendar: Self.calendar)
            == dueFriday)
        // A start days earlier.
        #expect(TaskDay.due(dueFriday, notBefore: PacificTestCalendar.date(2026, 11, 10, 9), calendar: Self.calendar)
            == dueFriday)
    }

    @Test func dueMovesToTheDayAfterAStartThatPassedIt() {
        let dueFriday = TaskDay.due(on: PacificTestCalendar.date(2026, 11, 13, 9), calendar: Self.calendar)
        // Start on Monday Nov 16: due becomes Tuesday Nov 17, 17:00 PST, still without a time.
        let monday = TaskDay.notBefore(on: PacificTestCalendar.date(2026, 11, 16, 9), calendar: Self.calendar)
        let moved = TaskDay.due(dueFriday, notBefore: monday, calendar: Self.calendar)
        #expect(moved == Self.instant("2026-11-18T01:00:00Z"))
        #expect(!TaskDay.dueHasTime(moved, calendar: Self.calendar))
        // A start late on the due day, after the deadline: the day after the start's local day.
        // Friday 22:30 PST is already Saturday in UTC; the new deadline is Saturday, not Sunday.
        #expect(TaskDay.due(dueFriday, notBefore: PacificTestCalendar.date(2026, 11, 13, 22, 30), calendar: Self.calendar)
            == Self.instant("2026-11-15T01:00:00Z"))
        // A start at the deadline's own instant leaves no time either.
        #expect(TaskDay.due(dueFriday, notBefore: dueFriday, calendar: Self.calendar) == Self.instant("2026-11-15T01:00:00Z"))
    }

    @Test func aMovedDueKeepsItsClockTime() {
        // "By 3 PM Friday", start moved to Wednesday Nov 18 at 10:00: due Thursday Nov 19, 3 PM PST.
        let byThree = PacificTestCalendar.date(2026, 11, 13, 15, 0)
        let moved = TaskDay.due(byThree, notBefore: PacificTestCalendar.date(2026, 11, 18, 10), calendar: Self.calendar)
        #expect(moved == Self.instant("2026-11-19T23:00:00Z"))
        #expect(TaskDay.dueHasTime(moved, calendar: Self.calendar))
        // The server's end-of-day default for a repeating task stays an end of day.
        let endOfFriday = Self.instant("2026-11-14T07:59:59.999Z")
        let endOfDay = TaskDay.due(endOfFriday, notBefore: PacificTestCalendar.date(2026, 11, 18, 10), calendar: Self.calendar)
        #expect(Self.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: endOfDay)
            == DateComponents(year: 2026, month: 11, day: 19, hour: 23, minute: 59))
        #expect(!TaskDay.dueHasTime(endOfDay, calendar: Self.calendar))
    }

    @Test func aMovedDueIsFiveOClockAcrossAClockChange() {
        // Clocks go forward on Sunday March 8, 2026. Due Friday Mar 6 (17:00 PST), start Saturday
        // Mar 7: due Sunday Mar 8 at 17:00 PDT, which is midnight UTC, not 01:00.
        let dueFriday = TaskDay.due(on: PacificTestCalendar.date(2026, 3, 6, 9), calendar: Self.calendar)
        let saturday = TaskDay.notBefore(on: PacificTestCalendar.date(2026, 3, 7, 9), calendar: Self.calendar)
        #expect(TaskDay.due(dueFriday, notBefore: saturday, calendar: Self.calendar) == Self.instant("2026-03-09T00:00:00Z"))
    }
}
