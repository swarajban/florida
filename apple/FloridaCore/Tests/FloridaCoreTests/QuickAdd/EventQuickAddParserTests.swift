import Foundation
import Testing
@testable import FloridaCore

private func eventCalendar(_ zone: String = "America/Los_Angeles") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private let eventLA = eventCalendar()

private func eventDate(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
    calendar: Calendar = eventLA
) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func eventParse(
    _ text: String, now: Date = eventDate(2026, 11, 8, 9), calendar: Calendar = eventLA,
    defaultStart: Date? = nil
) -> EventQuickAddDraft {
    EventQuickAddParser.parse(text, now: now, calendar: calendar, defaultStart: defaultStart)
}

@Suite struct EventQuickAddParserTests {
    @Test func lunchRangeAndDentistDuration() {
        let lunch = eventParse("lunch with Dana tomorrow 12-1")
        #expect(lunch.title == "lunch with Dana")
        #expect(lunch.startAt == eventDate(2026, 11, 9, 12))
        #expect(lunch.endAt == eventDate(2026, 11, 9, 13))
        #expect(!lunch.allDay)
        let dentist = eventParse("dentist fri 3pm 45m")
        #expect(dentist.title == "dentist")
        #expect(dentist.startAt == eventDate(2026, 11, 13, 15))
        #expect(dentist.endAt == eventDate(2026, 11, 13, 15, 45))
    }

    @Test func templateAndFallbackDefaults() {
        let template = eventDate(2026, 12, 3, 16, 15)
        let draft = eventParse("  Catch   up  ", defaultStart: template)
        #expect(draft.title == "Catch up")
        #expect(draft.startAt == template)
        #expect(draft.endAt == template.addingTimeInterval(1800))
        #expect(draft.recurrence == nil)
        #expect(draft.location == nil)
        #expect(draft.notes == nil)
        #expect(draft.calendarHint == nil)
        let fallback = eventParse("")
        #expect(fallback.title == "")
        #expect(fallback.startAt == eventDate(2026, 11, 8, 9))
        #expect(fallback.endAt == eventDate(2026, 11, 8, 9, 30))
        #expect(eventParse("Call for 2h", defaultStart: template).endAt == template.addingTimeInterval(7200))
    }

    @Test func explicitDayAndClockIgnoreTemplate() {
        let template = eventDate(2027, 1, 1, 17)
        let dateOnly = eventParse("Visit tomorrow", defaultStart: template)
        #expect(dateOnly.startAt == eventDate(2026, 11, 9, 9))
        #expect(dateOnly.endAt == eventDate(2026, 11, 9, 9, 30))
        #expect(eventParse("Visit today", now: eventDate(2026, 11, 8, 18)).startAt == eventDate(2026, 11, 8, 9))
        #expect(eventParse("Visit at 3pm", defaultStart: template).startAt == eventDate(2026, 11, 8, 15))
        #expect(eventParse("Visit at 8am", defaultStart: template).startAt == eventDate(2026, 11, 9, 8))
        #expect(eventParse("Visit at 9am").startAt == eventDate(2026, 11, 9, 9))
    }

    @Test func clockDateOrderAndBareHours() {
        for text in ["Call tomorrow at 3 pm", "Call 3pm tomorrow", "Call on tomorrow at 15:00", "Call tomorrow 15"] {
            let draft = eventParse(text)
            #expect(draft.title == "Call", "\(text)")
            #expect(draft.startAt == eventDate(2026, 11, 9, 15), "\(text)")
        }
        #expect(eventParse("Call at 9").startAt == eventDate(2026, 11, 9, 9))
        #expect(eventParse("Table 9").title == "Table 9")
        #expect(eventParse("Call tomorrow 2 hours").endAt == eventDate(2026, 11, 9, 11))
        #expect(eventParse("Call tomorrow at noon").startAt == eventDate(2026, 11, 9, 12))
        #expect(eventParse("Call tomorrow midnight").startAt == eventDate(2026, 11, 10))
    }

    @Test func rangesInheritMeridiemAndCrossMidnight() {
        let cases: [(String, Int, Int, Int, Int, Int)] = [
            ("12-1", 12, 0, 13, 0, 9),
            ("12-1pm", 12, 0, 13, 0, 9),
            ("11-1pm", 11, 0, 13, 0, 9),
            ("9-5pm", 9, 0, 17, 0, 9),
            ("3pm-4", 15, 0, 16, 0, 9),
            ("11pm-1", 23, 0, 1, 0, 10),
            ("11-1am", 23, 0, 1, 0, 10),
            ("11pm-1am", 23, 0, 1, 0, 10),
            ("23:30-01:15", 23, 30, 1, 15, 10),
            ("9:30-10:45pm", 21, 30, 22, 45, 9),
            ("12am-1am", 0, 0, 1, 0, 9),
            ("noon-midnight", 12, 0, 0, 0, 10),
            ("9am-8am", 9, 0, 8, 0, 10),
            ("9am-9am", 9, 0, 9, 0, 10),
        ]
        for (range, startHour, startMinute, endHour, endMinute, endDay) in cases {
            let draft = eventParse("Call tomorrow \(range)")
            #expect(draft.title == "Call", "\(range)")
            #expect(draft.startAt == eventDate(2026, 11, 9, startHour, startMinute), "\(range)")
            #expect(draft.endAt == eventDate(2026, 11, endDay, endHour, endMinute), "\(range)")
        }
    }

    @Test func rangeSpacingAndRangeBeatsDuration() {
        for range in ["3 - 4 pm", "3pm – 4pm", "3 pm—4 pm", "3pm- 4pm", "3pm -4pm", "3pm to 4pm"] {
            let draft = eventParse("Call from \(range) tomorrow 2h")
            #expect(draft.title == "Call", "\(range)")
            #expect(draft.startAt == eventDate(2026, 11, 9, 15), "\(range)")
            #expect(draft.endAt == eventDate(2026, 11, 9, 16), "\(range)")
        }
    }

    @Test func sharedDurationFormsAndOnlyFirstWins() {
        let cases: [(String, Int)] = [
            ("2h", 120), ("30m", 30), ("45min", 45), ("1h30m", 90), ("1h30", 90),
            ("1h 30m", 90), ("1.5h", 90), ("90 min", 90), ("2 hours", 120),
            ("for 2h", 120), ("~2h", 120), ("2 hours 15 min", 135),
        ]
        for (text, minutes) in cases {
            let draft = eventParse("Call tomorrow 10am \(text)")
            #expect(draft.title == "Call", "\(text)")
            #expect(draft.endAt.timeIntervalSince(draft.startAt) == Double(minutes) * 60, "\(text)")
        }
        #expect(eventParse("Call 2h 3h").title == "Call 3h")
    }

    @Test func dateGrammarRemainsMonthFirstAndStrictlyFuture() {
        let cases: [(String, Int, Int, Int)] = [
            ("tmrw", 2026, 11, 9), ("tmr", 2026, 11, 9), ("eod", 2026, 11, 8),
            ("eow", 2026, 11, 13), ("fri", 2026, 11, 13), ("sun", 2026, 11, 15),
            ("next fri", 2026, 11, 20), ("next week", 2026, 11, 16),
            ("11/12", 2026, 11, 12), ("1/5", 2027, 1, 5), ("11/20/27", 2027, 11, 20),
            ("2026-11-20", 2026, 11, 20), ("nov 20th", 2026, 11, 20),
            ("20 nov", 2026, 11, 20), ("nov 20, 2027", 2027, 11, 20),
        ]
        for (text, year, month, day) in cases {
            let draft = eventParse("Visit \(text)")
            #expect(draft.title == "Visit", "\(text)")
            #expect(draft.startAt == eventDate(year, month, day, 9), "\(text)")
        }
        for text in ["2/30", "13/1", "2026-13-01", "25pm", "9:60", "0m", "2hour-long"] {
            #expect(eventParse("Visit \(text)").title == "Visit \(text)", "\(text)")
        }
    }

    @Test func allDayStoresUTCMidnightsAndExclusiveEnd() {
        for zone in ["America/Los_Angeles", "Asia/Kolkata", "Pacific/Kiritimati", "America/New_York"] {
            let calendar = eventCalendar(zone)
            let now = eventDate(2026, 3, 7, 14, calendar: calendar)
            for marker in ["all day", "ALL-DAY", "allday"] {
                let draft = eventParse("Holiday tomorrow \(marker)", now: now, calendar: calendar)
                #expect(draft.title == "Holiday")
                #expect(draft.allDay)
                #expect(draft.startAt == eventDate(2026, 3, 8, calendar: eventCalendar("UTC")))
                #expect(draft.endAt == eventDate(2026, 3, 9, calendar: eventCalendar("UTC")))
                let days = AllDayDate.localDays(start: draft.startAt, end: draft.endAt, calendar: calendar)
                #expect(days.lowerBound == eventDate(2026, 3, 8, calendar: calendar))
                #expect(days.upperBound == eventDate(2026, 3, 9, calendar: calendar))
            }
        }
        let template = eventDate(2026, 12, 1, 23)
        #expect(eventParse("Holiday all day", defaultStart: template).startAt
            == eventDate(2026, 12, 1, calendar: eventCalendar("UTC")))
        #expect(eventParse("Holiday all day tomorrow 3pm 2h").endAt
            == eventDate(2026, 11, 10, calendar: eventCalendar("UTC")))
    }

    @Test func clocksUseSuppliedZoneAndDurationsAreElapsedTime() {
        let india = eventCalendar("Asia/Kolkata")
        let now = eventDate(2026, 11, 8, 9)
        let draft = eventParse("Call tomorrow 12-1", now: now, calendar: india)
        #expect(draft.startAt == eventDate(2026, 11, 9, 6, 30, calendar: eventCalendar("UTC")))
        #expect(draft.endAt == eventDate(2026, 11, 9, 7, 30, calendar: eventCalendar("UTC")))
        let spring = eventParse("Call 2026-03-08 1:30am 2h")
        #expect(spring.endAt == eventDate(2026, 3, 8, 4, 30))
        let fall = eventParse("Call 2026-11-01 12:30am 3h")
        #expect(fall.endAt == eventDate(2026, 11, 1, 2, 30))
        let springRange = eventParse("Call 2026-03-08 1:30am-3:30am")
        #expect(springRange.endAt.timeIntervalSince(springRange.startAt) == 3600)
        let fallRange = eventParse("Call 2026-11-01 12:30am-2:30am")
        #expect(fallRange.endAt.timeIntervalSince(fallRange.startAt) == 10_800)
        let missingClock = eventParse("Call 2026-03-08 at 2:30am")
        #expect(missingClock.startAt == eventDate(2026, 3, 8, 3, 30))
    }

    @Test func locationDoesNotEatClockOrMetadata() {
        for text in [
            "Coffee at Blue Bottle tomorrow at 3pm #personal // bring laptop",
            "Coffee tomorrow at 3pm at Blue Bottle #personal // bring laptop",
            "Coffee #personal at Blue Bottle on tomorrow 3pm // bring laptop",
        ] {
            let draft = eventParse(text)
            #expect(draft.title == "Coffee", "\(text)")
            #expect(draft.location == "Blue Bottle", "\(text)")
            #expect(draft.calendarHint == "personal")
            #expect(draft.startAt == eventDate(2026, 11, 9, 15))
            #expect(draft.notes == "bring laptop")
        }
        #expect(eventParse("Meet at Studio 54").location == "Studio 54")
        #expect(eventParse("Meet at").title == "Meet at")
        #expect(eventParse("Meet at Blue Bottle for").location == "Blue Bottle for")
        #expect(eventParse("Meet at 3pm").location == nil)
        #expect(eventParse("Meet at Blue Bottle for 45m").endAt == eventDate(2026, 11, 8, 9, 45))
    }

    @Test func firstHintAndNotesFollowTaskGrammar() {
        let draft = eventParse("Plan #Work_Events #q4 -- notes tomorrow 5pm #other")
        #expect(draft.title == "Plan #q4")
        #expect(draft.calendarHint == "Work_Events")
        #expect(draft.notes == "notes tomorrow 5pm #other")
        #expect(draft.startAt == eventDate(2026, 11, 8, 9))
        #expect(eventParse("Plan #").calendarHint == "")
        #expect(eventParse("Plan # #work").title == "Plan #work")
        #expect(eventParse("Plan #bad!").title == "Plan #bad!")
        #expect(eventParse("Plan --").notes == nil)
        #expect(eventParse("Plan http://example.com").title == "Plan http://example.com")
    }

    @Test func recurrenceFrequenciesAndIntervals() {
        let cases: [(String, EventRecurrence.Frequency, Int)] = [
            ("daily", .daily, 1), ("weekly", .weekly, 1), ("monthly", .monthly, 1), ("yearly", .yearly, 1),
            ("every day", .daily, 1), ("every 3 days", .daily, 3), ("every 2 weeks", .weekly, 2),
            ("every other week", .weekly, 2), ("every 4 months", .monthly, 4), ("every 99 years", .yearly, 99),
        ]
        let template = eventDate(2026, 12, 1, 13)
        for (text, frequency, interval) in cases {
            let draft = eventParse("Check in \(text)", defaultStart: template)
            #expect(draft.title == "Check in", "\(text)")
            #expect(draft.startAt == template)
            #expect(draft.recurrence == EventRecurrence(
                frequency: frequency, interval: interval, timeZone: "America/Los_Angeles"), "\(text)")
        }
    }

    @Test func weekdayRecurrenceAnchorsFirstOccurrence() {
        let draft = eventParse("Standup every tuesday at 10am 45m #work")
        #expect(draft.title == "Standup")
        #expect(draft.startAt == eventDate(2026, 11, 10, 10))
        #expect(draft.endAt == eventDate(2026, 11, 10, 10, 45))
        #expect(draft.recurrence?.frequency == .weekly)
        #expect(draft.recurrence?.interval == 1)
        #expect(eventParse("Standup every 2 tuesdays 10").startAt == eventDate(2026, 11, 10, 10))
        #expect(eventParse("Standup every sun").startAt == eventDate(2026, 11, 15, 9))
        #expect(eventParse("Standup every tuesday starting 11/17").startAt == eventDate(2026, 11, 17, 9))
        #expect(eventParse("Standup every tuesday starting tomorrow").startAt == eventDate(2026, 11, 10, 9))
        #expect(eventParse("Standup every tuesday starting 11/18").startAt == eventDate(2026, 11, 24, 9))
        let allDay = eventParse("Holiday every year all day 2026-12-25")
        #expect(allDay.allDay)
        #expect(allDay.recurrence?.frequency == .yearly)
        #expect(allDay.startAt == eventDate(2026, 12, 25, calendar: eventCalendar("UTC")))
    }

    @Test func unsupportedRecurrenceRemainsLiteral() {
        for text in [
            "every weekday", "every 0 weeks", "every 100 weeks", "every 100 tuesday",
            "every monday and wednesday", "every monday,wednesday", "every monday, wednesday",
            "weekly on monday and wednesday", "every week on monday and wednesday",
        ] {
            let draft = eventParse("Call \(text) 3pm")
            #expect(draft.title == "Call \(text)", "\(text)")
            #expect(draft.recurrence == nil, "\(text)")
            #expect(draft.startAt == eventDate(2026, 11, 8, 15), "\(text)")
        }
        let draft = eventParse("Call every other tuesday at Blue Bottle 3pm")
        #expect(draft.location == "Blue Bottle")
        #expect(draft.recurrence?.interval == 2)
        #expect(draft.startAt == eventDate(2026, 11, 10, 15))
    }

    @Test func draftHasPublicMutableValueSemantics() {
        var draft = EventQuickAddDraft(title: "Call", startAt: eventDate(2026, 11, 9, 9), endAt: eventDate(2026, 11, 9, 10))
        draft.title = "Visit"
        draft.location = "Home"
        draft.calendarHint = "personal"
        draft.notes = "Bring keys"
        draft.recurrence = EventRecurrence(frequency: .daily, timeZone: "America/Los_Angeles")
        draft.startAt = eventDate(2026, 11, 10)
        draft.endAt = eventDate(2026, 11, 11)
        draft.allDay = true
        #expect(Set([draft, draft]).count == 1)
    }
}

@Suite struct EventQuickAddCalendarMatchingTests {
    private func calendar(
        _ id: String, _ summary: String, googleId: String? = nil, accountId: String = "account", role: String = "owner"
    ) -> CalendarInfo {
        CalendarInfo(id: id, accountId: accountId, googleId: googleId ?? id, summary: summary,
                     accessRole: role, selected: false, updatedAt: eventDate(2026, 11, 8))
    }

    @Test func exactNameIdAndEmailBeatPrefix() {
        let work = calendar("work-id", "Work", googleId: "work@example.com")
        let team = calendar("team-id", "Work Team")
        for hint in ["WORK", " work ", "work_id", "WORK@example.com"] {
            #expect(EventQuickAddParser.matchingCalendars(hint: hint, in: [team, work], accounts: []) == [work])
        }
        #expect(EventQuickAddParser.matchingCalendars(hint: "work-t", in: [work, team], accounts: []) == [team])
    }

    @Test func ambiguousNamesAndPrefixesReturnAllInInputOrder() {
        let one = calendar("1", "Work Engineering")
        let two = calendar("2", "Work Infosec", role: "writer")
        let three = calendar("3", "Work Engineering")
        #expect(EventQuickAddParser.matchingCalendars(hint: "work", in: [two, one, three], accounts: []) == [two, one, three])
        #expect(EventQuickAddParser.matchingCalendars(hint: "work-engineering", in: [two, one, three], accounts: []) == [one, three])
        #expect(EventQuickAddParser.matchingCalendars(hint: "unknown", in: [one, two], accounts: []).isEmpty)
        #expect(EventQuickAddParser.matchingCalendars(hint: "", in: [one, two], accounts: []).isEmpty)
    }

    @Test func onlyWritableCalendarsParticipateAndVisibilityDoesNotMatter() {
        let reader = calendar("reader", "Work", role: "reader")
        let freeBusy = calendar("free", "Work", role: "freeBusyReader")
        let writer = calendar("writer", "Work Team", role: "writer")
        let owner = calendar("owner", "Work Other")
        #expect(EventQuickAddParser.matchingCalendars(hint: "work", in: [reader, freeBusy, writer, owner], accounts: []) == [writer, owner])
        #expect(EventQuickAddParser.matchingCalendars(hint: "reader", in: [reader, writer], accounts: []).isEmpty)
    }

    @Test func slugsNormalizePunctuationAndWhitespace() {
        let family = calendar("family", " A&S  Family Calendar ")
        let work = calendar("work", "Work   Engineering")
        #expect(EventQuickAddParser.matchingCalendars(hint: "a-s-family", in: [family, work], accounts: []) == [family])
        #expect(EventQuickAddParser.matchingCalendars(hint: "work_engineering", in: [family, work], accounts: []) == [work])
        #expect(EventQuickAddParser.matchingCalendars(hint: "---", in: [family, work], accounts: []).isEmpty)
    }

    @Test func accountAliasNamesOnlyItsPrimaryCalendar() {
        let account = GoogleAccount(id: "account", email: "me@example.com", label: "Personal", updatedAt: eventDate(2026, 11, 8))
        let primary = calendar("primary", "My Calendar", googleId: "ME@example.com")
        let shared = calendar("shared", "Shared Calendar", googleId: "shared@example.com")
        let other = calendar("other", "Other Calendar", googleId: "me@example.com", accountId: "other")
        #expect(EventQuickAddParser.matchingCalendars(hint: "personal", in: [shared, other, primary], accounts: [account]) == [primary])
        #expect(EventQuickAddParser.matchingCalendars(hint: "me@example.com", in: [shared, other, primary], accounts: [account]) == [other, primary])
    }
}
