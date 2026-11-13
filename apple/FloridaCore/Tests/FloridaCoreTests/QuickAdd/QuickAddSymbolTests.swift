import Foundation
import Testing
@testable import FloridaCore

@Suite struct QuickAddSymbolTests {
    private let calendar = PacificTestCalendar.calendar
    private let now = PacificTestCalendar.date(2026, 11, 12, 10)

    private func parse(_ text: String) -> QuickAddDraft {
        QuickAddParser.parse(text, now: now, calendar: calendar)
    }

    @Test(arguments: ["today", "tomorrow", "fri", "nov 20", "20 nov", "11/20", "2026-11-20", "next week", "in 2 weeks", "fri 3pm", "tomorrow at 9", "5pm", "midnight"])
    func symbolicDueUsesExistingMomentGrammar(_ phrase: String) {
        let legacy = parse("Work by \(phrase)")
        for prefix in ["^", "^ "] {
            let draft = parse("Work \(prefix)\(phrase)")
            #expect(draft.title == legacy.title)
            #expect(draft.dueAt == legacy.dueAt)
            #expect(draft.dueAt != nil)
            #expect(draft.deadlineType == .soft)
            #expect(draft.pinnedStart == nil)
        }
    }

    @Test(arguments: ["tomorrow", "fri 9am", "in 2 days", "nov 20", "next week", "3pm"])
    func symbolicStartUsesExistingMomentGrammar(_ phrase: String) {
        let legacy = parse("Work after \(phrase)")
        for prefix in ["~", "~ "] {
            let draft = parse("Work \(prefix)\(phrase)")
            #expect(draft.title == legacy.title)
            #expect(draft.startAt == legacy.startAt)
            #expect(draft.startAt != nil)
            #expect(draft.dueAt == nil)
            #expect(draft.pinnedStart == nil)
        }
    }

    @Test(arguments: ["45m", "1h30m", "1h 30m", "1.5h", "90 min", "2 hours", "2 hours 15 min"])
    func equalsDurationUsesExistingDurationGrammar(_ phrase: String) {
        for prefix in ["=", "= "] {
            let draft = parse("Work \(prefix)\(phrase)")
            #expect(draft.title == "Work")
            #expect(draft.durationMinutes == parse("Work \(phrase)").durationMinutes)
            #expect(draft.durationMinutes != nil)
        }
    }

    @Test func somedayOverridesEarlierDatesAndLaterDatesResumeScheduling() {
        let draft = parse("Work ^NONE #work")
        #expect(draft.someday)
        #expect(draft.title == "Work")
        #expect(draft.dueAt == nil)
        #expect(draft.deadlineType == nil)
        #expect(parse("Work ^ none").someday)
        #expect(!QuickAddDraft().someday)
        #expect(QuickAddDraft().recurrence == nil)
        #expect(parse("Work ^none ^fri").title == "Work")
        #expect(parse("Work ^none by fri").title == "Work")
        #expect(parse("Work ^none tomorrow").title == "Work")
        #expect(parse("Work ^none ^none").title == "Work ^none")
        #expect(parse("Work ^fri ^none").someday)
        #expect(parse("Work ^fri ^none").title == "Work")
        #expect(parse("Work due fri ^none").someday)
        #expect(parse("Work ^none at 3pm").pinnedStart != nil)
        #expect(!parse("Work ^none at 3pm").someday)
    }

    @Test func numericPrioritiesAndNames() {
        let groups: [(Priority, [String])] = [
            (.asap, ["!1", "!asap", "!urgent", "p1"]),
            (.high, ["!2", "!high", "!h", "p2"]),
            (.medium, ["!3", "!medium", "!med", "!m", "p3"]),
            (.low, ["!4", "!low", "!l", "p4"]),
        ]
        for (priority, tokens) in groups {
            for token in tokens {
                let draft = parse("Work \(token.uppercased())")
                #expect(draft.title == "Work")
                #expect(draft.priority == priority)
            }
        }
        #expect(parse("Work !1 !4").title == "Work !4")
        #expect(parse("Work !0 !5 !12").priority == nil)
    }

    @Test func recurrencePresets() throws {
        let cases: [(String, TaskRecurrence.Frequency, Int, [Int]?)] = [
            ("daily", .day, 1, nil), ("weekly", .week, 1, nil), ("monthly", .month, 1, nil),
            ("every 2 weeks", .week, 2, nil), ("every 3 days", .day, 3, nil),
            ("every 2 months", .month, 2, nil), ("every week", .week, 1, nil),
            ("weekdays", .week, 1, [1, 2, 3, 4, 5]), ("weekends", .week, 1, [0, 6]),
            ("mon wed", .week, 1, [1, 3]), ("every monday wednesday", .week, 1, [1, 3]),
            ("wed,mon mon", .week, 1, [1, 3]), ("sun sat", .week, 1, [0, 6]),
        ]
        for (phrase, frequency, interval, weekdays) in cases {
            for prefix in ["*", "* "] {
                let draft = parse("Work \(prefix)\(phrase.uppercased())")
                let rule = try #require(draft.recurrence, "\(phrase)")
                #expect(draft.title == "Work")
                #expect(rule.frequency == frequency)
                #expect(rule.interval == interval)
                #expect(rule.weekdays == weekdays)
                #expect(rule.startDate == "2026-11-12")
                #expect(rule.timeZone == "America/Los_Angeles")
                #expect(rule.validationMessage == nil)
                #expect(draft.dueAt == nil)
            }
        }
    }

    @Test func recurrenceUsesStartAnchorRegardlessOfTokenOrder() throws {
        for text in ["Work *weekly ~nov 20", "Work ~nov 20 *weekly", "Work *weekly after nov 20"] {
            let rule = try #require(parse(text).recurrence)
            #expect(rule.startDate == "2026-11-20")
            #expect(rule.effectiveWeekdays == [5])
        }
        #expect(parse("Work *daily at 3pm tomorrow").recurrence?.startDate == "2026-11-13")
        #expect(parse("Work *daily ^nov 20").recurrence?.startDate == "2026-11-20")
        #expect(parse("Work *weekly at 3pm tomorrow ~nov 20").recurrence?.startDate == "2026-11-20")
    }

    @Test func recurrencePreservesExplicitDueDateAnchor() throws {
        let draft = parse("Review ^fri *weekly")
        let rule = try #require(draft.recurrence)
        #expect(rule.startDate == "2026-11-13")
        #expect(rule.effectiveWeekdays == [5])
        #expect(rule.firstOccurrence == PacificTestCalendar.date(2026, 11, 13))
        #expect(draft.dueAt == PacificTestCalendar.date(2026, 11, 13, 17))
        #expect(parse("Review *weekly ~today ^fri").recurrence?.startDate == "2026-11-13")
        let weekdays = try #require(parse("Review ^fri *mon wed").recurrence)
        #expect(weekdays.firstOccurrence == PacificTestCalendar.date(2026, 11, 16))
    }

    @Test func invalidAndDuplicateSymbolClausesStayLiteral() {
        for phrase in ["^nonsense", "^2026-02-30", "=0m", "=bad", "~nonsense", "*nonsense", "*every 0 weeks", "*every 1000 weeks", "*every 9223372036854775807 weeks", "^", "=", "*", "=9223372036854775807h"] {
            let draft = parse("Work \(phrase)")
            #expect(draft.title == "Work \(phrase)")
            #expect(draft.recurrence == nil)
            #expect(draft.dueAt == nil)
            #expect(draft.durationMinutes == nil)
            #expect(draft.startAt == nil)
        }
        #expect(parse("Work =30m =1h 15m").title == "Work =1h 15m")
        #expect(parse("Work ~today ~next week").title == "Work ~next week")
        #expect(parse("Work ^today ^next week").title == "Work ^next week")
        #expect(parse("Work *daily *mon wed").title == "Work *mon wed")
        #expect(parse("Work 30m =1h").durationMinutes == 30)
        #expect(parse("Work ~2h").durationMinutes == 120)
        #expect(parse("Work ~1.5h").durationMinutes == 90)
        #expect(parse("Work ~2 hours").durationMinutes == 120)
    }

    @Test func allSymbolsComposeAndNotesAreOpaque() {
        let draft = parse("Write update #work @office ^fri !2 *mon wed =45m ~tomorrow // https://example.com/#x ^none !1 *daily =2h")
        #expect(draft.title == "Write update")
        #expect(draft.categoryHint == "work")
        #expect(draft.context == .office)
        #expect(draft.dueAt == PacificTestCalendar.date(2026, 11, 13, 17))
        #expect(draft.priority == .high)
        #expect(draft.durationMinutes == 45)
        #expect(draft.startAt == PacificTestCalendar.date(2026, 11, 13))
        #expect(draft.recurrence?.weekdays == [1, 3])
        #expect(draft.recurrence?.startDate == "2026-11-13")
        #expect(!draft.someday)
        #expect(draft.notes == "https://example.com/#x ^none !1 *daily =2h")
        #expect(parse("Write #work #q4").title == "Write #q4")
        #expect(parse("Write //").title == "Write")
        #expect(parse("Write //").notes == nil)
    }

    @Test func embeddedSymbolsAndURLsRemainLiteral() {
        for text in ["Email person@home.com", "Read C# and a^fri b!1 c*weekly d=45m e~tomorrow f//notes", "Read #work#q4", "Read @office.example", "Read a~", "Read path/to/", "~literal"] {
            #expect(parse(text) == QuickAddDraft(title: text))
        }
        for url in ["https://example.com/^fri?x=!1&y=*weekly#work", "https://example.com//notes", "https://example.com/", "https://example.com/?q=1;", "mailto:jane@example.com?subject=Plan;", "mailto:jane@example.com?subject=Plan."] {
            #expect(parse("Read " + url) == QuickAddDraft(title: "Read", source: TaskSource.from(url: url)))
            let sourceURL = "https://source.example/task"
            #expect(parse(sourceURL + " Read " + url) == QuickAddDraft(title: "Read " + url, source: TaskSource.from(url: sourceURL)))
        }
    }

    @Test func sourceLinksAndSmartAddFieldsStayIndependent() {
        let url = "https://example.com/^none?priority=!1&repeat=*daily#wrong"
        let draft = parse("Review \(url) #work ^fri !2 *weekly =45m ~today // Keep https://notes.example/^none")
        #expect(draft.source?.url == url)
        #expect(draft.title == "Review")
        #expect(draft.categoryHint == "work")
        #expect(draft.dueAt != nil)
        #expect(!draft.someday)
        #expect(draft.priority == .high)
        #expect(draft.recurrence?.frequency == .week)
        #expect(draft.durationMinutes == 45)
        #expect(draft.startAt != nil)
        #expect(draft.notes == "Keep https://notes.example/^none")
    }

    @Test func notesDoNotRequireASeparatorAfterTheSlashes() {
        for separator in ["//", "// ", "//\n"] {
            let draft = parse("Work #work " + separator + "Check the draft ^none !1 *weekly =2h ~tomorrow #personal @home")
            #expect(draft.title == "Work")
            #expect(draft.categoryHint == "work")
            #expect(draft.notes == "Check the draft ^none !1 *weekly =2h ~tomorrow #personal @home")
            #expect(draft.dueAt == nil)
            #expect(!draft.someday)
            #expect(draft.priority == nil)
            #expect(draft.recurrence == nil)
            #expect(draft.durationMinutes == nil)
            #expect(draft.startAt == nil)
            #expect(draft.context == nil)
        }
        #expect(parse("Work //").notes == nil)
        #expect(parse("Work --Check draft").title == "Work --Check draft")
        #expect(parse("Work -- Check draft").notes == "Check draft")
        #expect(parse("Work f//notes").title == "Work f//notes")
        #expect(parse("Work https://example.com//notes").notes == nil)
    }

    @Test func symbolicDatesRespectDSTAndLocalDay() {
        let draft = QuickAddParser.parse(
            "Work ~in 2 days ^in 2 days 3pm *weekly", now: PacificTestCalendar.date(2027, 3, 13, 23), calendar: calendar)
        #expect(draft.startAt == PacificTestCalendar.date(2027, 3, 15))
        #expect(draft.dueAt == PacificTestCalendar.date(2027, 3, 15, 15))
        #expect(draft.recurrence?.startDate == "2027-03-15")
    }
}
