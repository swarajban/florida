import Foundation
import Testing
@testable import FloridaCore

/// 2026-11-08T17:00:00Z: Sunday 09:00 in Los Angeles, Sunday 22:30 in Kolkata.
private let sundayMorning = Date(timeIntervalSince1970: 1_794_157_200)

private func calendar(in zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private let losAngeles = calendar(in: "America/Los_Angeles")

private func local(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in calendar: Calendar = losAngeles
) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func parse(_ text: String, now: Date = sundayMorning, calendar: Calendar = losAngeles) -> QuickAddDraft {
    QuickAddParser.parse(text, now: now, calendar: calendar)
}

@Suite struct QuickAddParserTests {
    @Test func fullLineWithDurationProjectDeadlineAndPriority() {
        let draft = parse("Write design doc 2h #work by fri !high")
        #expect(draft.title == "Write design doc")
        #expect(draft.durationMinutes == 120)
        #expect(draft.projectHint == "work")
        #expect(draft.priority == .high)
        #expect(draft.deadlineType == .soft)
        #expect(draft.dueAt == local(2026, 11, 13, 17, 0))
        #expect(draft.dueAt == Date(timeIntervalSince1970: 1_794_618_000)) // 2026-11-14T01:00:00Z
        #expect(draft.startAt == nil)
        #expect(draft.pinnedStart == nil)
        #expect(draft.notes == nil)
    }

    @Test func bareDateIsSoftDeadlineAtEndOfWorkday() {
        let draft = parse("Call mom 30m tomorrow")
        #expect(draft.title == "Call mom")
        #expect(draft.durationMinutes == 30)
        #expect(draft.deadlineType == .soft)
        #expect(draft.dueAt == local(2026, 11, 9, 17, 0))
    }

    @Test func dueKeywordIsHardDeadline() {
        let draft = parse("Taxes due 11/20 4h p1")
        #expect(draft.title == "Taxes")
        #expect(draft.deadlineType == .hard)
        #expect(draft.dueAt == local(2026, 11, 20, 17, 0))
        #expect(draft.durationMinutes == 240)
        #expect(draft.priority == .asap)
    }

    @Test func weekdayWithClockPinsStart() {
        let draft = parse("Standup prep tue 10am 15m")
        #expect(draft.title == "Standup prep")
        #expect(draft.pinnedStart == local(2026, 11, 10, 10, 0))
        #expect(draft.durationMinutes == 15)
        #expect(draft.dueAt == nil)
        #expect(draft.deadlineType == nil)
    }

    @Test func atClockPinsToTodayWhenStillAhead() {
        let draft = parse("Review PR at 3pm")
        #expect(draft.title == "Review PR")
        #expect(draft.pinnedStart == local(2026, 11, 8, 15, 0))
        #expect(draft.dueAt == nil)
    }

    @Test func atClockRollsToTomorrowWhenPassed() {
        let draft = parse("Review PR at 8am")
        #expect(draft.pinnedStart == local(2026, 11, 9, 8, 0))
    }

    @Test func afterAndByTogether() {
        let draft = parse("Plan offsite after mon by fri")
        #expect(draft.title == "Plan offsite")
        #expect(draft.startAt == local(2026, 11, 9, 0, 0))
        #expect(draft.dueAt == local(2026, 11, 13, 17, 0))
        #expect(draft.deadlineType == .soft)
    }

    @Test func asapInsideSentenceIsNotPriority() {
        let draft = parse("Read the asap project brief")
        #expect(draft.title == "Read the asap project brief")
        #expect(draft.priority == nil)
    }

    @Test func asapAtEndIsPriority() {
        let draft = parse("reply to Jane asap")
        #expect(draft.title == "reply to Jane")
        #expect(draft.priority == .asap)
    }

    @Test func asapWithColonAtStartIsPriority() {
        let draft = parse("asap: reply to Jane")
        #expect(draft.title == "reply to Jane")
        #expect(draft.priority == .asap)
    }

    @Test func urgentAtEndOfTitleWordsEvenWhenTokensFollow() {
        let draft = parse("reply to Jane urgent #work")
        #expect(draft.title == "reply to Jane")
        #expect(draft.priority == .asap)
        #expect(draft.projectHint == "work")
    }

    @Test func explicitPriorityBeatsBareWord() {
        let draft = parse("reply to Jane asap !low")
        #expect(draft.priority == .low)
        #expect(draft.title == "reply to Jane asap")
    }

    @Test func monthNameDateAndNotes() {
        let draft = parse("Renew passport by nov 20 // bring old one")
        #expect(draft.title == "Renew passport")
        #expect(draft.dueAt == local(2026, 11, 20, 17, 0))
        #expect(draft.deadlineType == .soft)
        #expect(draft.notes == "bring old one")
    }

    @Test func dashNotesAreNotScannedForTokens() {
        let draft = parse("Fix login -- see 2h estimate by fri")
        #expect(draft.title == "Fix login")
        #expect(draft.notes == "see 2h estimate by fri")
        #expect(draft.durationMinutes == nil)
        #expect(draft.dueAt == nil)
    }

    @Test func hoursAndMinutesWithLowPriorityAndHyphenatedProject() {
        let draft = parse("Fix flaky test 1h30m !low #work-infra")
        #expect(draft.title == "Fix flaky test")
        #expect(draft.durationMinutes == 90)
        #expect(draft.priority == .low)
        #expect(draft.projectHint == "work-infra")
    }

    @Test func dueClockWithoutDateIsTodayWhenStillAhead() {
        let draft = parse("Pay rent due 5pm")
        #expect(draft.title == "Pay rent")
        #expect(draft.dueAt == local(2026, 11, 8, 17, 0))
        #expect(draft.deadlineType == .hard)
    }

    @Test func byClockWithoutDateRollsToTomorrowWhenPassed() {
        let sixPM = local(2026, 11, 8, 18, 0)
        let draft = parse("Pay rent by 5pm", now: sixPM)
        #expect(draft.dueAt == local(2026, 11, 9, 17, 0))
        #expect(draft.deadlineType == .soft)
    }

    @Test func weekdayMatchingTodayMeansNextWeek() {
        let draft = parse("Gym sun 7am")
        #expect(draft.title == "Gym")
        #expect(draft.pinnedStart == local(2026, 11, 15, 7, 0))
    }

    @Test func nextWeekdayIsAfterComingSunday() {
        let draft = parse("Prep next mon")
        #expect(draft.title == "Prep")
        #expect(draft.dueAt == local(2026, 11, 16, 17, 0))
        #expect(draft.deadlineType == .soft)
    }

    @Test func onlyFirstDurationCounts() {
        let draft = parse("Something with 2h of stuff and 3h more")
        #expect(draft.durationMinutes == 120)
        #expect(draft.title == "Something with of stuff and 3h more")
    }

    @Test func emptyTextIsEmptyDraft() {
        #expect(parse("") == QuickAddDraft(title: ""))
        #expect(parse("   \t ") == QuickAddDraft(title: ""))
    }

    @Test func defaultDueTimeFollowsCalendarTimeZone() {
        let kolkata = calendar(in: "Asia/Kolkata")
        let draft = parse("Call mom tomorrow", calendar: kolkata)
        #expect(draft.dueAt == local(2026, 11, 9, 17, 0, in: kolkata))
        #expect(draft.dueAt == Date(timeIntervalSince1970: 1_794_223_800)) // 2026-11-09T11:30:00Z
        #expect(draft.dueAt != local(2026, 11, 9, 17, 0))
    }

    @Test func dateThenAtClockPinsStart() {
        let draft = parse("Dentist tomorrow at 3pm")
        #expect(draft.title == "Dentist")
        #expect(draft.pinnedStart == local(2026, 11, 9, 15, 0))
        #expect(draft.dueAt == nil)
    }

    @Test func clockThenDatePinsStart() {
        let draft = parse("Dentist at 3pm tomorrow")
        #expect(draft.title == "Dentist")
        #expect(draft.pinnedStart == local(2026, 11, 9, 15, 0))
    }

    @Test func bareHourAfterDateIsClock() {
        let draft = parse("Dentist tomorrow 9")
        #expect(draft.title == "Dentist")
        #expect(draft.pinnedStart == local(2026, 11, 9, 9, 0))
    }

    @Test func bareNumberElsewhereStaysInTitle() {
        let draft = parse("Buy 9 apples tomorrow")
        #expect(draft.title == "Buy 9 apples")
        #expect(draft.dueAt == local(2026, 11, 9, 17, 0))
        #expect(draft.pinnedStart == nil)
    }

    @Test func byDateWithClockOverridesDefault() {
        #expect(parse("Ship by fri 3pm").dueAt == local(2026, 11, 13, 15, 0))
        #expect(parse("Ship by fri at 3pm").dueAt == local(2026, 11, 13, 15, 0))
        #expect(parse("Ship due tomorrow 9:30").dueAt == local(2026, 11, 9, 9, 30))
        #expect(parse("Ship deadline 2026-11-20").deadlineType == .hard)
        #expect(parse("Ship deadline 2026-11-20").dueAt == local(2026, 11, 20, 17, 0))
    }

    @Test func startKeywordsAcceptClock() {
        let draft = parse("Deep work after mon 9am")
        #expect(draft.startAt == local(2026, 11, 9, 9, 0))
        #expect(parse("Deep work from tue").startAt == local(2026, 11, 10, 0, 0))
        #expect(parse("Deep work starting friday").startAt == local(2026, 11, 13, 0, 0))
        #expect(parse("Deep work start 11/20").startAt == local(2026, 11, 20, 0, 0))
    }

    @Test func midnightMeansEndOfTheNamedDay() {
        #expect(parse("Submit due fri midnight").dueAt == local(2026, 11, 14, 0, 0))
        #expect(parse("Submit by midnight").dueAt == local(2026, 11, 9, 0, 0))
    }

    @Test func keywordsWithoutDatesStayInTitle() {
        #expect(parse("Lunch at Joe's").title == "Lunch at Joe's")
        #expect(parse("Email from Bob").title == "Email from Bob")
        #expect(parse("Start the report").title == "Start the report")
        #expect(parse("Book by Tolkien").title == "Book by Tolkien")
        #expect(parse("Due diligence memo").title == "Due diligence memo")
        #expect(parse("Form 2 teams").title == "Form 2 teams")
        #expect(parse("Form 2 teams").durationMinutes == nil)
    }

    @Test func forPrefixAndTwoTokenDurations() {
        #expect(parse("Nap for 2h").durationMinutes == 120)
        #expect(parse("Nap for 2h").title == "Nap")
        #expect(parse("Run 90 min").durationMinutes == 90)
        #expect(parse("Run 90 min").title == "Run")
        #expect(parse("Study 2 hours").durationMinutes == 120)
        #expect(parse("Study ~1.5h").durationMinutes == 90)
        #expect(parse("Study 1h 30m").durationMinutes == 90)
        #expect(parse("Study 1h 30m").title == "Study")
    }

    @Test func priorityShorthands() {
        #expect(parse("x !asap").priority == .asap)
        #expect(parse("x !urgent").priority == .asap)
        #expect(parse("x !h").priority == .high)
        #expect(parse("x !med").priority == .medium)
        #expect(parse("x !m").priority == .medium)
        #expect(parse("x !l").priority == .low)
        #expect(parse("x P2").priority == .high)
        #expect(parse("x p3").priority == .medium)
        #expect(parse("x p4").priority == .low)
    }

    @Test func laterDuplicateTokensStayInTitle() {
        let draft = parse("Plan #work #q4 !high !low")
        #expect(draft.projectHint == "work")
        #expect(draft.priority == .high)
        #expect(draft.title == "Plan #q4 !low")
    }

    @Test func projectHintKeepsCaseAndRejectsOtherCharacters() {
        #expect(parse("x #Personal_Finances").projectHint == "Personal_Finances")
        #expect(parse("x #1").projectHint == "1")
        #expect(parse("Issue #work!").projectHint == nil)
        #expect(parse("Issue #work!").title == "Issue #work!")
    }

    @Test func titleTrimsSeparatorPunctuation() {
        #expect(parse("- buy milk tomorrow").title == "buy milk")
        #expect(parse("Call mom - 30m").title == "Call mom")
        #expect(parse("Should I go?").title == "Should I go?")
    }

    @Test func endOfDayAndEndOfWeek() {
        #expect(parse("Report eod").dueAt == local(2026, 11, 8, 17, 0))
        #expect(parse("Report by eow").dueAt == local(2026, 11, 13, 17, 0))
        #expect(parse("Report next week").dueAt == local(2026, 11, 16, 17, 0))
    }

    @Test func pastMonthDayRollsToNextYear() {
        #expect(parse("Taxes by 1/5").dueAt == local(2027, 1, 5, 17, 0))
        #expect(parse("Taxes by jan 5").dueAt == local(2027, 1, 5, 17, 0))
        #expect(parse("Taxes by 11/8").dueAt == local(2026, 11, 8, 17, 0))
    }
}

@Suite struct QuickAddScannerTests {
    private func scanner(_ text: String, now: Date = sundayMorning, calendar: Calendar = losAngeles) -> QuickAddScanner {
        QuickAddScanner(text: text, now: now, calendar: calendar)
    }

    @Test func durationForms() throws {
        let cases: [(String, Int, Int)] = [
            ("2h", 120, 1), ("30m", 30, 1), ("45min", 45, 1), ("1h30m", 90, 1), ("1h30", 90, 1),
            ("1.5h", 90, 1), ("2hr", 120, 1), ("2hrs", 120, 1), ("~2h", 120, 1), ("2h15min", 135, 1),
            ("90 min", 90, 2), ("2 hours", 120, 2), ("1 hour", 60, 2), ("30 mins", 30, 2),
            ("1h 30m", 90, 2), ("2 hours 15 min", 135, 4), ("~2 hours", 120, 2),
        ]
        for (text, minutes, consumed) in cases {
            let result = try #require(scanner(text).parseDuration(at: 0), "\(text)")
            #expect(result.minutes == minutes, "\(text)")
            #expect(result.consumed == consumed, "\(text)")
        }
    }

    @Test func notDurations() {
        for text in ["Form", "2", "2 m", "2hour-long", ".5h", "0m", "h", "2x", "3pm", "10am", "2 teams"] {
            #expect(scanner(text).parseDuration(at: 0) == nil, "\(text)")
        }
    }

    @Test func clockForms() throws {
        let cases: [(String, Int, Int, Int)] = [
            ("3pm", 15, 0, 1), ("3:30pm", 15, 30, 1), ("15:00", 15, 0, 1), ("9am", 9, 0, 1),
            ("12am", 0, 0, 1), ("12pm", 12, 0, 1), ("12:30am", 0, 30, 1), ("noon", 12, 0, 1),
            ("midnight", 24, 0, 1), ("3 pm", 15, 0, 2), ("3:30 pm", 15, 30, 2), ("0:00", 0, 0, 1),
        ]
        for (text, hour, minute, consumed) in cases {
            let result = try #require(scanner(text).parseClock(at: 0, allowBareHour: false), "\(text)")
            #expect(result.clock == QuickAddScanner.Clock(hour: hour, minute: minute), "\(text)")
            #expect(result.consumed == consumed, "\(text)")
        }
    }

    @Test func bareHourOnlyWhenAllowed() {
        #expect(scanner("9").parseClock(at: 0, allowBareHour: false) == nil)
        #expect(scanner("9").parseClock(at: 0, allowBareHour: true)?.clock == QuickAddScanner.Clock(hour: 9, minute: 0))
        #expect(scanner("23").parseClock(at: 0, allowBareHour: true)?.clock == QuickAddScanner.Clock(hour: 23, minute: 0))
        for text in ["24", "13pm", "0am", "9:60", "9:5", "9h", "abc", "2026"] {
            #expect(scanner(text).parseClock(at: 0, allowBareHour: true) == nil, "\(text)")
        }
    }

    @Test func relativeDates() {
        #expect(scanner("today").parseDate(at: 0)?.day == local(2026, 11, 8))
        #expect(scanner("eod").parseDate(at: 0)?.day == local(2026, 11, 8))
        #expect(scanner("tomorrow").parseDate(at: 0)?.day == local(2026, 11, 9))
        #expect(scanner("tmrw").parseDate(at: 0)?.day == local(2026, 11, 9))
        #expect(scanner("tmr").parseDate(at: 0)?.day == local(2026, 11, 9))
        #expect(scanner("eow").parseDate(at: 0)?.day == local(2026, 11, 13))
        #expect(scanner("mon").parseDate(at: 0)?.day == local(2026, 11, 9))
        #expect(scanner("Saturday").parseDate(at: 0)?.day == local(2026, 11, 14))
        #expect(scanner("sun").parseDate(at: 0)?.day == local(2026, 11, 15))
        #expect(scanner("next week").parseDate(at: 0)?.day == local(2026, 11, 16))
        #expect(scanner("next week").parseDate(at: 0)?.consumed == 2)
        #expect(scanner("next mon").parseDate(at: 0)?.day == local(2026, 11, 16))
        #expect(scanner("next sun").parseDate(at: 0)?.day == local(2026, 11, 22))
        #expect(scanner("next").parseDate(at: 0) == nil)
        #expect(scanner("next thing").parseDate(at: 0) == nil)
    }

    @Test func endOfWeekOnFridayIsToday() {
        let friday = local(2026, 11, 13, 9, 0)
        #expect(scanner("eow", now: friday).parseDate(at: 0)?.day == local(2026, 11, 13))
        let saturday = local(2026, 11, 14, 9, 0)
        #expect(scanner("eow", now: saturday).parseDate(at: 0)?.day == local(2026, 11, 20))
    }

    @Test func nextWeekdayFromMidweek() {
        let wednesday = local(2026, 11, 11, 9, 0)
        #expect(scanner("next mon", now: wednesday).parseDate(at: 0)?.day == local(2026, 11, 16))
        #expect(scanner("next fri", now: wednesday).parseDate(at: 0)?.day == local(2026, 11, 20))
        #expect(scanner("fri", now: wednesday).parseDate(at: 0)?.day == local(2026, 11, 13))
    }

    @Test func numericDates() {
        #expect(scanner("11/20").parseDate(at: 0)?.day == local(2026, 11, 20))
        #expect(scanner("11/20/2026").parseDate(at: 0)?.day == local(2026, 11, 20))
        #expect(scanner("11/20/27").parseDate(at: 0)?.day == local(2027, 11, 20))
        #expect(scanner("2026-11-20").parseDate(at: 0)?.day == local(2026, 11, 20))
        #expect(scanner("1/5").parseDate(at: 0)?.day == local(2027, 1, 5))
        for text in ["2/30", "13/1", "11/0", "2026-13-01", "11/20/202", "work-infra", "1/2/3/4", "/5"] {
            #expect(scanner(text).parseDate(at: 0) == nil, "\(text)")
        }
    }

    @Test func monthNameDates() {
        #expect(scanner("nov 20").parseDate(at: 0)?.day == local(2026, 11, 20))
        #expect(scanner("nov 20").parseDate(at: 0)?.consumed == 2)
        #expect(scanner("nov 20th").parseDate(at: 0)?.day == local(2026, 11, 20))
        #expect(scanner("20 nov").parseDate(at: 0)?.day == local(2026, 11, 20))
        #expect(scanner("20th november").parseDate(at: 0)?.day == local(2026, 11, 20))
        #expect(scanner("Nov 1st").parseDate(at: 0)?.day == local(2027, 11, 1))
        #expect(scanner("nov 20, 2027").parseDate(at: 0)?.day == local(2027, 11, 20))
        #expect(scanner("nov 20, 2027").parseDate(at: 0)?.consumed == 3)
        #expect(scanner("nov").parseDate(at: 0) == nil)
        #expect(scanner("nov 31").parseDate(at: 0) == nil)
        #expect(scanner("nov 20 2h").parseDate(at: 0)?.consumed == 2)
    }

    @Test func momentCombinations() throws {
        let dateThenClock = try #require(scanner("fri 3pm").parseMoment(at: 0, bareHourFirst: false))
        #expect(dateThenClock.day == local(2026, 11, 13))
        #expect(dateThenClock.clock == QuickAddScanner.Clock(hour: 15, minute: 0))
        #expect(dateThenClock.consumed == 2)

        let dateAtClock = try #require(scanner("fri at 3pm").parseMoment(at: 0, bareHourFirst: false))
        #expect(dateAtClock.consumed == 3)

        let dateThenDuration = try #require(scanner("fri 2 hours").parseMoment(at: 0, bareHourFirst: false))
        #expect(dateThenDuration.clock == nil)
        #expect(dateThenDuration.consumed == 1)

        let clockThenDate = try #require(scanner("3pm fri").parseMoment(at: 0, bareHourFirst: false))
        #expect(clockThenDate.day == local(2026, 11, 13))
        #expect(clockThenDate.consumed == 2)

        #expect(scanner("9").parseMoment(at: 0, bareHourFirst: false) == nil)
        #expect(scanner("9").parseMoment(at: 0, bareHourFirst: true)?.clock == QuickAddScanner.Clock(hour: 9, minute: 0))
    }

    @Test func splitNotesOnlyAtStandaloneSeparators() {
        let slashes = QuickAddScanner.splitNotes("Fix a // b // c")
        #expect(slashes.body == "Fix a ")
        #expect(slashes.notes == "b // c")
        let dashes = QuickAddScanner.splitNotes("Fix a -- b")
        #expect(dashes.notes == "b")
        #expect(QuickAddScanner.splitNotes("Fix a --").notes == nil)
        #expect(QuickAddScanner.splitNotes("Fix a --").body == "Fix a ")
        #expect(QuickAddScanner.splitNotes("http://x.y/z").notes == nil)
        #expect(QuickAddScanner.splitNotes("well--known").notes == nil)
    }
}
