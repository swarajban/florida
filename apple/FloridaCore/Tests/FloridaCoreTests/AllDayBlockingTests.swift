import Foundation
import Testing
@testable import FloridaCore

@Suite struct AllDayBlockingTests {
    func event() -> CalendarEvent {
        CalendarEvent(id: "e", calendarId: "cal", googleId: "g-e", summary: "Holiday", allDay: true, updatedAt: .distantPast)
    }

    @Test func olderEventsAndAccountsHaveNoJudgmentOrDisplayName() throws {
        let data = Data("""
            {"id":"e","calendarId":"cal","googleId":"g-e","status":"confirmed","allDay":true,"updatedAt":"2026-11-08T00:00:00Z"}
            """.utf8)
        let event = try JSONCoding.decoder.decode(CalendarEvent.self, from: data)
        #expect(event.autoBlocksDay == nil && event.blockingReason == nil)
        let account = try JSONCoding.decoder.decode(GoogleAccount.self, from: Data("""
            {"id":"acct","email":"me@example.com","label":"personal","updatedAt":"2026-11-08T00:00:00Z"}
            """.utf8))
        #expect(account.displayName == nil)
    }

    @Test(arguments: [nil, true, false] as [Bool?], [nil, true, false] as [Bool?])
    func manualWinsThenJudgmentThenOOOFallback(manual: Bool?, automatic: Bool?) {
        for outOfOffice in [false, true] {
            var event = event()
            event.eventType = outOfOffice ? "outOfOffice" : "default"
            event.blocksDay = manual
            event.autoBlocksDay = automatic
            #expect(AllDayBlocking.isEffective(event, calendarBlocksScheduling: true) == (manual ?? automatic ?? outOfOffice))
            #expect(!AllDayBlocking.isEffective(event, calendarBlocksScheduling: false))
        }
    }

    @Test func judgmentsRoundTripButNeverEnterGoogleWriteBodies() throws {
        var event = event()
        event.autoBlocksDay = false
        event.blockingReason = "A teammate is out of office, not you."
        event.blocksDay = true
        event.startAt = Date(timeIntervalSince1970: 1_794_182_400)
        event.endAt = event.startAt!.addingTimeInterval(86_400)
        let data = try JSONCoding.encoder.encode(event)
        #expect(try JSONCoding.decoder.decode(CalendarEvent.self, from: data) == event)
        let write = try #require(EventWrite(event))
        let body = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(write)) as? [String: Any])
        #expect(body["blocksDay"] as? Bool == true)
        #expect(body["autoBlocksDay"] == nil && body["blockingReason"] == nil)
        let account = GoogleAccount(id: "acct", email: "me@example.com", label: "personal", updatedAt: .distantPast, displayName: "Swaraj Banerjee")
        #expect(try JSONCoding.decoder.decode(GoogleAccount.self, from: JSONCoding.encoder.encode(account)) == account)
    }

    @Test func timedCancelledDeletedAndDeclinedEventsDoNotProtectDays() {
        var event = event()
        event.blocksDay = true
        event.allDay = false
        #expect(!AllDayBlocking.isEffective(event, calendarBlocksScheduling: true))
        event.allDay = true
        event.status = "cancelled"
        #expect(!AllDayBlocking.isEffective(event, calendarBlocksScheduling: true))
        event.status = "confirmed"
        event.deletedAt = .distantPast
        #expect(!AllDayBlocking.isEffective(event, calendarBlocksScheduling: true))
        event.deletedAt = nil
        event.responseStatus = "declined"
        #expect(!AllDayBlocking.isEffective(event, calendarBlocksScheduling: true))
    }

    @Test func reasonsDistinguishManualOverridesFromStoredAutomaticJudgment() {
        var event = event()
        event.autoBlocksDay = true
        event.blockingReason = "US public holiday."
        #expect(AllDayBlocking.explanation(for: event) == "Automatic: US public holiday.")
        event.blocksDay = false
        #expect(AllDayBlocking.explanation(for: event) == "Manual override: Does not block. Automatic: US public holiday.")
        event.blocksDay = true
        #expect(AllDayBlocking.explanation(for: event) == "Manual override: Blocks. Automatic: US public holiday.")
    }

    @Test func protectedDatesUseLocalCalendarDatesAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var event = event()
        event.startAt = JSONCoding.parseInstant("2026-11-01T00:00:00Z")
        event.endAt = JSONCoding.parseInstant("2026-11-03T00:00:00Z")
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(AllDayBlocking.events(on: first, from: [event], calendar: calendar) == [event])
        #expect(AllDayBlocking.events(on: DateNavigation.shift(first, by: 1, calendar: calendar), from: [event], calendar: calendar) == [event])
        #expect(AllDayBlocking.events(on: DateNavigation.shift(first, by: -1, calendar: calendar), from: [event], calendar: calendar).isEmpty)
        #expect(AllDayBlocking.events(on: DateNavigation.shift(first, by: 2, calendar: calendar), from: [event], calendar: calendar).isEmpty)
    }
}
