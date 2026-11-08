import Foundation
import Testing
@testable import FloridaCore

@Suite struct DateNavigationTests {
    let calendar = PacificTestCalendar.calendar
    let hour: TimeInterval = 3600

    func components(_ date: Date) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, weekday: Int) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        return (c.year!, c.month!, c.day!, c.hour!, c.minute!, c.weekday!)
    }

    @Test func startOfDayUsesCalendarTimeZone() {
        let afternoon = PacificTestCalendar.date(2026, 11, 4, 15, 30)
        let start = DateNavigation.startOfDay(afternoon, calendar: calendar)
        #expect(start == PacificTestCalendar.date(2026, 11, 4))
        #expect(components(start).hour == 0 && components(start).minute == 0)
    }

    @Test func startOfWeekHonorsMondayFirst() {
        // Wednesday 2026-11-04 → Monday 2026-11-02.
        let wednesday = PacificTestCalendar.date(2026, 11, 4, 9)
        #expect(DateNavigation.startOfWeek(for: wednesday, calendar: calendar) == PacificTestCalendar.date(2026, 11, 2))
        // Monday itself is already the start.
        #expect(DateNavigation.startOfWeek(for: PacificTestCalendar.date(2026, 11, 2, 23, 59), calendar: calendar) == PacificTestCalendar.date(2026, 11, 2))
        // Sunday belongs to the week starting the previous Monday.
        #expect(DateNavigation.startOfWeek(for: PacificTestCalendar.date(2026, 11, 8), calendar: calendar) == PacificTestCalendar.date(2026, 11, 2))
    }

    @Test func startOfWeekHonorsSundayFirst() {
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let wednesday = PacificTestCalendar.date(2026, 11, 4, 9)
        #expect(DateNavigation.startOfWeek(for: wednesday, calendar: sundayFirst) == PacificTestCalendar.date(2026, 11, 1))
        #expect(DateNavigation.startOfWeek(for: PacificTestCalendar.date(2026, 11, 1, 12), calendar: sundayFirst) == PacificTestCalendar.date(2026, 11, 1))
    }

    @Test func weekSpanningFallBackHasSevenLocalMidnights() {
        // Saturday 2026-10-31 is in the week Mon Oct 26 … Sun Nov 1; DST ends Sunday Nov 1 at 02:00.
        let days = DateNavigation.days(in: PacificTestCalendar.date(2026, 10, 31, 12), calendar: calendar)
        #expect(days.count == 7)
        let expected = [(10, 26), (10, 27), (10, 28), (10, 29), (10, 30), (10, 31), (11, 1)]
        for (day, (month, dayOfMonth)) in zip(days, expected) {
            let c = components(day)
            #expect(c.year == 2026 && c.month == month && c.day == dayOfMonth, "\(day)")
            #expect(c.hour == 0 && c.minute == 0, "\(day) is not local midnight")
        }
        #expect(days.map { components($0).weekday } == [2, 3, 4, 5, 6, 7, 1])
        // Consecutive midnights within the array are 24h apart; the day after Nov 1 is 25h away.
        for index in 1..<days.count {
            #expect(days[index].timeIntervalSince(days[index - 1]) == 24 * hour)
        }
        let range = DateNavigation.visibleRange(for: .week, anchor: PacificTestCalendar.date(2026, 10, 31, 12), calendar: calendar)
        #expect(range.lowerBound == days[0])
        #expect(range.upperBound == PacificTestCalendar.date(2026, 11, 2))
        #expect(range.upperBound.timeIntervalSince(days[6]) == 25 * hour)
        #expect(range.upperBound.timeIntervalSince(range.lowerBound) == (7 * 24 + 1) * hour)
    }

    @Test func weekStartingOnFallBackDayStaysAtMidnight() {
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let days = DateNavigation.days(in: PacificTestCalendar.date(2026, 11, 4), calendar: sundayFirst)
        #expect(days.count == 7)
        #expect(days.first == PacificTestCalendar.date(2026, 11, 1))
        #expect(days.last == PacificTestCalendar.date(2026, 11, 7))
        for day in days {
            #expect(components(day).hour == 0 && components(day).minute == 0, "\(day)")
        }
        // The 25-hour day is inside this week.
        #expect(days[1].timeIntervalSince(days[0]) == 25 * hour)
        #expect(days[2].timeIntervalSince(days[1]) == 24 * hour)
    }

    @Test func shiftKeepsWallClockAcrossDST() {
        let nov1 = PacificTestCalendar.date(2026, 11, 1)
        let nov2 = DateNavigation.shift(nov1, by: 1, calendar: calendar)
        #expect(nov2 == PacificTestCalendar.date(2026, 11, 2))
        #expect(nov2.timeIntervalSince(nov1) == 25 * hour)
        #expect(DateNavigation.shift(nov2, by: -1, calendar: calendar) == nov1)
        #expect(DateNavigation.shift(PacificTestCalendar.date(2026, 11, 4, 9), by: 7, calendar: calendar) == PacificTestCalendar.date(2026, 11, 11, 9))
        #expect(DateNavigation.shift(nov1, by: 0, calendar: calendar) == nov1)
    }

    @Test func dayAndThreeDayRanges() {
        let anchor = PacificTestCalendar.date(2026, 11, 4, 15)
        let day = DateNavigation.visibleRange(for: .day, anchor: anchor, calendar: calendar)
        #expect(day == PacificTestCalendar.date(2026, 11, 4)..<PacificTestCalendar.date(2026, 11, 5))
        let three = DateNavigation.visibleRange(for: .threeDays, anchor: anchor, calendar: calendar)
        #expect(three == PacificTestCalendar.date(2026, 11, 4)..<PacificTestCalendar.date(2026, 11, 7))
        #expect(DateNavigation.days(in: three, calendar: calendar).count == 3)

        // The fall-back day is 25 hours long.
        let dst = DateNavigation.visibleRange(for: .day, anchor: PacificTestCalendar.date(2026, 11, 1, 12), calendar: calendar)
        #expect(dst.upperBound.timeIntervalSince(dst.lowerBound) == 25 * hour)
    }

    @Test func monthRangeIsSixWeekGridFromWeekContainingFirst() {
        // November 2026 starts on a Sunday; with Monday first the grid starts Mon Oct 26 and
        // covers 42 days through Sun Dec 6.
        let range = DateNavigation.visibleRange(for: .month, anchor: PacificTestCalendar.date(2026, 11, 15, 8), calendar: calendar)
        #expect(range.lowerBound == PacificTestCalendar.date(2026, 10, 26))
        #expect(range.upperBound == PacificTestCalendar.date(2026, 12, 7))
        let days = DateNavigation.days(in: range, calendar: calendar)
        #expect(days.count == 42)
        #expect(days.last == PacificTestCalendar.date(2026, 12, 6))
        for day in days {
            #expect(components(day).hour == 0 && components(day).minute == 0, "\(day)")
        }

        // December 2026 starts on a Tuesday → grid starts Mon Nov 30.
        let december = DateNavigation.visibleRange(for: .month, anchor: PacificTestCalendar.date(2026, 12, 25), calendar: calendar)
        #expect(december.lowerBound == PacificTestCalendar.date(2026, 11, 30))
        #expect(DateNavigation.days(in: december, calendar: calendar).count == 42)
    }

    @Test func daysInRangeStartsAtMidnightOfLowerBound() {
        let range = PacificTestCalendar.date(2026, 11, 4, 10)..<PacificTestCalendar.date(2026, 11, 6, 1)
        let days = DateNavigation.days(in: range, calendar: calendar)
        #expect(days == [PacificTestCalendar.date(2026, 11, 4), PacificTestCalendar.date(2026, 11, 5), PacificTestCalendar.date(2026, 11, 6)])
        #expect(DateNavigation.days(in: PacificTestCalendar.date(2026, 11, 4)..<PacificTestCalendar.date(2026, 11, 4), calendar: calendar).isEmpty)
    }
}
