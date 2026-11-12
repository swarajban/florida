import Foundation
import Testing
@testable import FloridaCore

struct EventQuickAddSessionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_794_511_800)

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private var accounts: [GoogleAccount] {
        [
            GoogleAccount(id: "work", email: "me@sempre-health.com", label: "work", updatedAt: now),
            GoogleAccount(id: "personal", email: "me@gmail.com", label: "personal", updatedAt: now),
        ]
    }

    private var calendars: [CalendarInfo] {
        [
            CalendarInfo(id: "personal", accountId: "personal", googleId: "me@gmail.com", summary: "Personal", accessRole: "owner", selected: true, updatedAt: now),
            CalendarInfo(id: "team", accountId: "work", googleId: "team", summary: "Work Team", accessRole: "writer", selected: true, updatedAt: now),
            CalendarInfo(id: "primary", accountId: "work", googleId: "me@sempre-health.com", summary: "Sempre", accessRole: "owner", selected: false, updatedAt: now),
            CalendarInfo(id: "reader", accountId: "work", googleId: "reader", summary: "Read only", accessRole: "reader", selected: true, updatedAt: now),
        ]
    }

    private func session() -> EventQuickAddSession {
        EventQuickAddSession(event: CalendarEvent(
            id: "new-event", calendarId: "primary", googleId: "", startAt: date("2026-11-12T18:00:00Z"),
            endAt: date("2026-11-12T18:30:00Z"), updatedAt: now), now: now, calendar: calendar)
    }

    @Test func usesExistingCalendarOrderEvenWhenPrimaryHidden() throws {
        var session = session()
        session.updateText("Lunch today noon")
        #expect(session.destination(in: calendars, accounts: accounts)?.id == "primary")
        let event = try #require(session.event(in: calendars, accounts: accounts))
        #expect(event.calendarId == "primary")
        #expect(event.id == "new-event")
        #expect(event.attendees == nil)
        #expect(event.organizer == nil)
        #expect(event.googleId.isEmpty)
        #expect(session.event(in: calendars, accounts: []) == nil)
    }

    @Test func unknownAmbiguousAndReadOnlyHintsNeedChoice() {
        var session = session()
        for hint in ["#missing", "#", "#read-only"] {
            session.updateText("Lunch tomorrow noon \(hint)")
            #expect(session.destination(in: calendars, accounts: accounts) == nil)
            #expect(session.event(in: calendars, accounts: accounts) == nil)
            #expect(session.validationMessage(in: calendars, accounts: accounts) != nil)
        }
        let duplicate = CalendarInfo(id: "another", accountId: "personal", googleId: "another", summary: "Sempre", accessRole: "owner", selected: true, updatedAt: now)
        session.updateText("Lunch tomorrow noon #sempre")
        #expect(session.destination(in: calendars + [duplicate], accounts: accounts) == nil)
        session.chooseCalendar("personal")
        #expect(session.destination(in: calendars, accounts: accounts)?.id == "personal")
        #expect(session.event(in: calendars, accounts: accounts)?.calendarId == "personal")
    }

    @Test func changingHintDiscardsPriorCalendarChoice() {
        var session = session()
        session.updateText("Lunch tomorrow noon #missing")
        session.chooseCalendar("personal")
        session.updateText("Lunch with Dana tomorrow noon #missing")
        #expect(session.chosenCalendarID == "personal")
        session.updateText("Lunch with Dana tomorrow noon #sempre")
        #expect(session.chosenCalendarID == nil)
        #expect(session.destination(in: calendars, accounts: accounts)?.id == "primary")
    }

    @Test func correctionsSurviveTypingAndResetRestoresParsedValues() {
        var session = session()
        session.updateText("Lunch tomorrow noon at Blue Bottle")
        session.setTitle("Lunch with Dana")
        session.setLocation("Cafe Luna")
        session.setRecurrence(EventRecurrence(frequency: .monthly, interval: 2, timeZone: calendar.timeZone.identifier, count: 5))
        session.moveStart(to: date("2026-11-15T21:00:00Z"))
        let correctedStart = session.draft.startAt
        session.updateText("Lunch friday 3pm 45m at Office every week")
        #expect(session.draft.title == "Lunch with Dana")
        #expect(session.draft.location == "Cafe Luna")
        #expect(session.draft.startAt == correctedStart)
        #expect(session.draft.recurrence?.frequency == .monthly)
        #expect(session.draft.recurrence?.count == 5)
        session.resetCorrections()
        #expect(!session.hasCorrections)
        #expect(session.draft.title == "Lunch")
        #expect(session.draft.location == "Office")
        #expect(session.draft.recurrence?.frequency == .weekly)
        #expect(session.draft.startAt != correctedStart)
    }

    @Test func invalidEndAndRemovedCalendarCannotSave() {
        var session = session()
        session.updateText("Lunch tomorrow noon")
        session.setEnd(session.draft.startAt)
        #expect(session.validationMessage(in: calendars, accounts: accounts) == "The end must be after the start.")
        #expect(session.event(in: calendars, accounts: accounts) == nil)
        session.setEnd(session.draft.startAt.addingTimeInterval(60))
        session.chooseCalendar("personal")
        #expect(session.event(in: calendars.filter { $0.id != "personal" }, accounts: accounts) == nil)
        session.chooseCalendar("reader")
        #expect(session.event(in: calendars, accounts: accounts) == nil)
    }

    @Test func emptyTitleRequiresCorrectionButCanOpenDetails() {
        let session = session()
        #expect(session.event(in: calendars, accounts: accounts) == nil)
        #expect(session.event(in: calendars, accounts: accounts, allowUntitled: true) != nil)
    }

    @Test func allDayCorrectionsKeepExclusiveUTCDateStorageAcrossDST() {
        var session = session()
        session.updateText("Holiday 2026-03-07 9am")
        session.setAllDay(true)
        #expect(session.draft.startAt == date("2026-03-07T00:00:00Z"))
        #expect(session.draft.endAt == date("2026-03-08T00:00:00Z"))
        session.setEnd(date("2026-03-09T07:00:00Z"))
        #expect(session.draft.endAt == date("2026-03-10T00:00:00Z"))
        session.moveStart(to: date("2026-03-08T08:00:00Z"))
        #expect(session.draft.startAt == date("2026-03-08T00:00:00Z"))
        #expect(session.draft.endAt == date("2026-03-11T00:00:00Z"))
        #expect(session.localStart == date("2026-03-08T08:00:00Z"))
        #expect(session.localEnd == date("2026-03-10T07:00:00Z"))
        session.setAllDay(false)
        #expect(session.draft.startAt == date("2026-03-08T16:00:00Z"))
        #expect(session.draft.endAt.timeIntervalSince(session.draft.startAt) == 30 * 60)
    }
}
