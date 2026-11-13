import Foundation
import Testing
@testable import FloridaCore

@Suite struct AllDayBlockingTests {
    @Test(arguments: [
        ("2026-11-13", "2026-11-17", "2026-11-16T08:00:00Z"),
        ("2026-11-13", "2026-11-16", "2026-11-15T08:00:00Z"),
        ("2026-11-13", "2026-11-15", "2026-11-14T08:00:00Z"),
        ("2026-11-13", "2026-11-14", "2026-11-14T08:00:00Z"),
        ("2026-10-31", "2026-11-03", "2026-11-02T08:00:00Z"),
        ("2026-03-07", "2026-03-10", "2026-03-09T07:00:00Z"),
    ])
    func automaticTripsOpenLastCoveredDate(start: String, end: String, blockingEnd: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var event = event()
        event.autoBlocksDay = true
        event.blockingReason = "Your trip"
        event.startAt = JSONCoding.parseInstant("\(start)T00:00:00Z")
        event.endAt = JSONCoding.parseInstant("\(end)T00:00:00Z")
        let days = try #require(AllDayBlocking.protectedDays(for: event, calendar: calendar))
        #expect(days.upperBound == JSONCoding.parseInstant(blockingEnd))
        #expect(AllDayBlocking.events(on: days.lowerBound, from: [event], calendar: calendar) == [event])
        #expect(AllDayBlocking.events(on: days.upperBound, from: [event], calendar: calendar).isEmpty)
        let singleDay = event.endAt!.timeIntervalSince(event.startAt!) == 86_400
        #expect(AllDayBlocking.explanation(for: event) == (singleDay ? "Automatic: Your trip" : "Automatic: Your trip · last day open"))
        event.blocksDay = true
        let full = AllDayDate.localDays(start: event.startAt!, end: event.endAt!, calendar: calendar)
        #expect(AllDayBlocking.protectedDays(for: event, calendar: calendar) == full)
        #expect(AllDayBlocking.explanation(for: event).hasPrefix("Manual override: Blocks. Automatic:"))
        event.blocksDay = false
        #expect(!AllDayBlocking.isEffective(event, calendarBlocksScheduling: true))
        event.blocksDay = nil
        for reason in ["Company holiday", "Your time off", "Unclassified"] {
            event.blockingReason = reason
            #expect(AllDayBlocking.protectedDays(for: event, calendar: calendar) == full)
            #expect(AllDayBlocking.explanation(for: event) == "Automatic: \(reason)")
        }
    }

    @Test func schedulingSummaryDistinguishesTripCheckoutFromManualOverrides() {
        var event = event()
        event.autoBlocksDay = true
        event.blockingReason = "Your trip"
        event.startAt = JSONCoding.parseInstant("2026-11-13T00:00:00Z")
        event.endAt = JSONCoding.parseInstant("2026-11-16T00:00:00Z")
        #expect(AllDayBlocking.schedulingSummary(for: event, calendarBlocksScheduling: true)
                == "Blocks trip days; last day open")
        event.blocksDay = true
        #expect(AllDayBlocking.schedulingSummary(for: event, calendarBlocksScheduling: true) == "Blocks your day")
        event.blocksDay = false
        #expect(AllDayBlocking.schedulingSummary(for: event, calendarBlocksScheduling: true) == "Does not block scheduling")
        event.blocksDay = nil
        #expect(AllDayBlocking.schedulingSummary(for: event, calendarBlocksScheduling: false) == "Does not block scheduling")
        event.endAt = JSONCoding.parseInstant("2026-11-14T00:00:00Z")
        #expect(AllDayBlocking.schedulingSummary(for: event, calendarBlocksScheduling: true) == "Blocks your day")
        event.blockingReason = "Holiday"
        event.endAt = JSONCoding.parseInstant("2026-11-16T00:00:00Z")
        #expect(AllDayBlocking.schedulingSummary(for: event, calendarBlocksScheduling: true) == "Blocks your day")
    }

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
