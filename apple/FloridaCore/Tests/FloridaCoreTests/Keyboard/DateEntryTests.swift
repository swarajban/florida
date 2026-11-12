import Foundation
import Testing
@testable import FloridaCore

@Suite struct DateEntryTests {
    private let calendar = PacificTestCalendar.calendar
    private let now = PacificTestCalendar.date(2026, 11, 12, 10, 15)

    private func parse(_ text: String, now: Date? = nil) -> DateEntryResult {
        DateEntry.parse(text, now: now ?? self.now, calendar: calendar)
    }

    @Test func parsesDateGrammarAtLocalStartOfDay() {
        let cases: [(String, Date)] = [
            ("tomorrow", PacificTestCalendar.date(2026, 11, 13)),
            ("FRI", PacificTestCalendar.date(2026, 11, 13)),
            ("nov 20", PacificTestCalendar.date(2026, 11, 20)),
            ("in 2 weeks", PacificTestCalendar.date(2026, 11, 26)),
            ("in 1 day", PacificTestCalendar.date(2026, 11, 13)),
            ("in 0 days", PacificTestCalendar.date(2026, 11, 12)),
            ("in 2 months", PacificTestCalendar.date(2027, 1, 12)),
            ("2026-11-20", PacificTestCalendar.date(2026, 11, 20)),
        ]
        for (text, expected) in cases {
            #expect(parse(text) == .date(expected, hasTime: false), "\(text)")
        }
    }

    @Test func preservesExplicitClocks() {
        let cases: [(String, Date)] = [
            ("next mon 3pm", PacificTestCalendar.date(2026, 11, 16, 15)),
            ("tomorrow at 9:30", PacificTestCalendar.date(2026, 11, 13, 9, 30)),
            ("3pm", PacificTestCalendar.date(2026, 11, 12, 15)),
            ("noon", PacificTestCalendar.date(2026, 11, 12, 12)),
            ("midnight", PacificTestCalendar.date(2026, 11, 13)),
            ("at 3pm", PacificTestCalendar.date(2026, 11, 12, 15)),
            ("at 3", PacificTestCalendar.date(2026, 11, 13, 3)),
            ("3 pm tomorrow", PacificTestCalendar.date(2026, 11, 13, 15)),
            ("today midnight", PacificTestCalendar.date(2026, 11, 13)),
            ("  TOMORROW\nAT\t3PM  ", PacificTestCalendar.date(2026, 11, 13, 15)),
        ]
        for (text, expected) in cases {
            #expect(parse(text) == .date(expected, hasTime: true), "\(text)")
        }
        #expect(parse("3pm", now: PacificTestCalendar.date(2026, 11, 12, 16)) ==
            .date(PacificTestCalendar.date(2026, 11, 13, 15), hasTime: true))
    }

    @Test func clearIsExplicit() {
        #expect(parse("none") == .clear)
        #expect(parse(" \nNoNe\t") == .clear)
        #expect(parse("") == .invalid)
    }

    @Test func rejectsInvalidDatesAndStrayTokens() {
        for text in [
            " ", "3", "at", "at tomorrow", "next", "nov", "nov 31", "2/30", "2026-13-01",
            "13pm", "24:00", "9:60", "tomorrow at", "tomorrow 13pm", "tomorrow at nope",
            "tomorrow extra", "extra tomorrow", "none tomorrow", "tomorrow none", "today tomorrow",
            "tomorrow // notes", "tomorrow --", "tomorrow #work", "due tomorrow", "by fri",
            "in -1 days", "in 1.5 weeks", "in 2 years", "in days", "in 2", "in 2 weeks extra",
            "in 99999999999999999999999999999 days", "in 9223372036854775807 months",
        ] {
            #expect(parse(text) == .invalid, "\(text)")
        }
    }

    @Test func dateArithmeticCrossesDSTWithoutShiftingMidnight() {
        let spring = PacificTestCalendar.date(2027, 3, 13, 12)
        #expect(parse("in 2 days", now: spring) == .date(PacificTestCalendar.date(2027, 3, 15), hasTime: false))
        #expect(parse("tomorrow 3pm", now: spring) == .date(PacificTestCalendar.date(2027, 3, 14, 15), hasTime: true))
        #expect(parse("tomorrow 2:30am", now: spring) == .invalid)
        let fall = PacificTestCalendar.date(2026, 10, 31, 12)
        #expect(parse("in 2 days", now: fall) == .date(PacificTestCalendar.date(2026, 11, 2), hasTime: false))
        #expect(parse("tomorrow 1:30am", now: fall) == .date(PacificTestCalendar.date(2026, 11, 1, 1, 30), hasTime: true))
    }

    @Test func rollsYearsAndClampsCalendarMonths() {
        let newYearsEve = PacificTestCalendar.date(2026, 12, 31, 22)
        #expect(parse("tomorrow", now: newYearsEve) == .date(PacificTestCalendar.date(2027, 1, 1), hasTime: false))
        #expect(parse("jan 5", now: newYearsEve) == .date(PacificTestCalendar.date(2027, 1, 5), hasTime: false))
        #expect(parse("in 1 month", now: PacificTestCalendar.date(2027, 1, 31, 10)) ==
            .date(PacificTestCalendar.date(2027, 2, 28), hasTime: false))
    }

    @Test func respectsSuppliedTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 23))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13))!
        #expect(DateEntry.parse("tomorrow", now: now, calendar: calendar) == .date(tomorrow, hasTime: false))
    }

    @Test func quickChoicesHaveStableTitlesAndDistinctNumberShortcuts() {
        #expect(DateEntryQuickChoice.allCases.map(\.title) == ["Today", "Tomorrow", "This weekend", "Next week", "No date"])
        #expect(DateEntryQuickChoice.allCases.map(\.shortcut) == ["1", "2", "3", "4", "5"])
        let dates: [Date?] = [
            PacificTestCalendar.date(2026, 11, 12), PacificTestCalendar.date(2026, 11, 13),
            PacificTestCalendar.date(2026, 11, 14), PacificTestCalendar.date(2026, 11, 16), nil,
        ]
        for (choice, expected) in zip(DateEntryQuickChoice.allCases, dates) {
            #expect(DateEntry.quickDate(choice, now: now, calendar: calendar) == expected)
        }
    }

    @Test func quickDatesUseScannerWeekRulesAndCalendarDays() {
        let saturday = PacificTestCalendar.date(2026, 11, 14, 18)
        #expect(DateEntry.quickDate(.weekend, now: saturday, calendar: calendar) == PacificTestCalendar.date(2026, 11, 14))
        let sunday = PacificTestCalendar.date(2026, 11, 15, 10)
        #expect(DateEntry.quickDate(.weekend, now: sunday, calendar: calendar) == PacificTestCalendar.date(2026, 11, 15))
        #expect(DateEntry.quickDate(.nextWeek, now: sunday, calendar: calendar) == PacificTestCalendar.date(2026, 11, 23))
        let spring = PacificTestCalendar.date(2027, 3, 14, 12)
        #expect(DateEntry.quickDate(.tomorrow, now: spring, calendar: calendar) == PacificTestCalendar.date(2027, 3, 15))
        #expect(DateEntry.quickDate(.nextWeek, now: PacificTestCalendar.date(2026, 12, 31), calendar: calendar) ==
            PacificTestCalendar.date(2027, 1, 4))
    }

    @Test func weekendFollowsTheSuppliedCalendarLocale() {
        var calendar = self.calendar
        calendar.locale = Locale(identifier: "ar_SA")
        #expect(DateEntry.quickDate(.weekend, now: now, calendar: calendar) == PacificTestCalendar.date(2026, 11, 13))
        #expect(DateEntry.quickDate(.weekend, now: PacificTestCalendar.date(2026, 11, 13, 12), calendar: calendar) ==
            PacificTestCalendar.date(2026, 11, 13))
    }
}
