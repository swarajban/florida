import Foundation
import Testing
@testable import FloridaCore

@Suite struct QuickAddRelativeDateTests {
    private let calendar = PacificTestCalendar.calendar
    private let now = PacificTestCalendar.date(2026, 11, 12, 10)

    @Test func relativeDatesWorkWithDeadlineAndStartGrammar() {
        let due = QuickAddParser.parse("Ship report due in 2 weeks", now: now, calendar: calendar)
        #expect(due.title == "Ship report")
        #expect(due.dueAt == PacificTestCalendar.date(2026, 11, 26, 17))
        #expect(due.deadlineType == .hard)
        let start = QuickAddParser.parse("Review after in 1 month 9am", now: now, calendar: calendar)
        #expect(start.title == "Review")
        #expect(start.startAt == PacificTestCalendar.date(2026, 12, 12, 9))
        let pinned = QuickAddParser.parse("Call in 2 days at 3pm", now: now, calendar: calendar)
        #expect(pinned.title == "Call")
        #expect(pinned.pinnedStart == PacificTestCalendar.date(2026, 11, 14, 15))
    }

    @Test func relativeBareDatesKeepDefaultDeadlineTime() {
        let draft = QuickAddParser.parse("Review in 1 week", now: now, calendar: calendar)
        #expect(draft.title == "Review")
        #expect(draft.dueAt == PacificTestCalendar.date(2026, 11, 19, 17))
        #expect(draft.deadlineType == .soft)
        #expect(draft.durationMinutes == nil)
    }

    @Test func invalidRelativePhrasesRemainTitleText() {
        for phrase in ["in -1 days", "in 1.5 weeks", "in days", "in 2 years", "in 9223372036854775807 weeks"] {
            let draft = QuickAddParser.parse("Review \(phrase)", now: now, calendar: calendar)
            #expect(draft.title == "Review \(phrase)")
            #expect(draft.dueAt == nil)
            #expect(draft.pinnedStart == nil)
        }
    }

    @Test func relativeDatesPreserveLocalClockAcrossDSTAndYearBoundaries() {
        let draft = QuickAddParser.parse("Ship in 2 days 3pm", now: PacificTestCalendar.date(2027, 3, 13, 10), calendar: calendar)
        #expect(draft.pinnedStart == PacificTestCalendar.date(2027, 3, 15, 15))
        let rollover = QuickAddParser.parse("Ship in 2 weeks", now: PacificTestCalendar.date(2026, 12, 31, 10), calendar: calendar)
        #expect(rollover.dueAt == PacificTestCalendar.date(2027, 1, 14, 17))
    }
}
