import Foundation
import Testing
@testable import FloridaKit

struct EventGuestStoreTests {
    func queued(_ db: AppDatabase) throws -> EventWrite {
        let pending = try #require(try db.pendingWrites().first)
        return try JSONCoding.decoder.decode(EventWrite.self, from: try #require(pending.body))
    }

    @Test func createCoalesceAndExplicitRemovalSurviveOmittedGuestEdits() throws {
        let db = try AppDatabase.inMemory()
        var event = Fixtures.event(id: "e", start: "2026-11-18T10:00:00Z", end: "2026-11-18T11:00:00Z", responseStatus: nil)
        event.googleId = ""
        try db.saveEvent(event, attendees: [EventAttendeeWrite(email: " ALICE@acme.com "), EventAttendeeWrite(email: "alice@acme.com")])
        #expect(try db.event(id: "e")?.attendees == [EventAttendee(email: "alice@acme.com")])
        #expect(try queued(db).attendees == [EventAttendeeWrite(email: "alice@acme.com")])
        event.summary = "Rename offline"
        try db.saveEvent(event)
        #expect(try queued(db).attendees?.map(\.email) == ["alice@acme.com"])
        #expect(try db.event(id: "e")?.attendees?.map(\.email) == ["alice@acme.com"])
        try db.saveEvent(event, attendees: [])
        try db.saveEvent(event)
        #expect(try queued(db).attendees == [])
        #expect(try db.event(id: "e")?.attendees == [])
    }

    @Test func editingMergesLiveMetadataPreservesProtectedRowsAndCombinesRSVP() throws {
        let db = try AppDatabase.inMemory()
        var event = Fixtures.event(id: "e", start: "2026-11-18T10:00:00Z", end: "2026-11-18T11:00:00Z", responseStatus: "needsAction")
        event.attendees = [
            EventAttendee(email: "owner@acme.com", responseStatus: "accepted", organizer: true),
            EventAttendee(email: "me@acme.com", isSelf: true),
            EventAttendee(email: "ALICE@acme.com", displayName: "Alice", responseStatus: "tentative", optional: true),
            EventAttendee(email: "remove@acme.com"),
        ]
        try db.apply(SyncResponse(cursor: "c", events: [event]))
        var draft = event
        draft.responseStatus = "accepted"
        try db.saveEvent(draft, original: event, attendees: [EventAttendeeWrite(email: "alice@acme.com"), EventAttendeeWrite(email: "new@acme.com")])
        let saved = try #require(try db.event(id: "e"))
        #expect(saved.attendees?.map(\.email) == ["owner@acme.com", "me@acme.com", "ALICE@acme.com", "new@acme.com"])
        #expect(saved.attendees?[1].responseStatus == "accepted")
        #expect(saved.attendees?[2].responseStatus == "tentative")
        #expect(saved.attendees?[2].displayName == "Alice")
        #expect(saved.attendees?[2].optional == false)
        #expect(saved.attendees?[3].responseStatus == "needsAction")
        #expect(try queued(db).responseStatus == "accepted")
        try db.moveEventSeries(instanceId: "e", start: saved.startAt!, end: saved.endAt!)
        #expect(try queued(db).attendees?.count == 2)
        try db.saveEvent(saved, original: saved, attendees: [])
        #expect(try queued(db).attendees == [])
        #expect(try db.event(id: "e")?.attendees?.map(\.email) == ["owner@acme.com", "me@acme.com"])
    }

    @Test func suggestionsReadCalendarsAndHistoryWithoutNetwork() throws {
        let db = try AppDatabase.inMemory()
        let account = Fixtures.account()
        var calendar = Fixtures.calendar()
        calendar.googleId = "coworker@acme.com"
        calendar.summary = "Coworker"
        var own = Fixtures.calendar(id: "own")
        own.googleId = account.email
        var group = Fixtures.calendar(id: "group")
        group.googleId = "holiday@group.v.calendar.google.com"
        var event = Fixtures.event(id: "e", start: "2026-11-18T10:00:00Z", end: "2026-11-18T11:00:00Z")
        event.attendees = [EventAttendee(email: "friend@acme.com", displayName: "Friend"), EventAttendee(email: "self@acme.com", isSelf: true)]
        try db.apply(SyncResponse(cursor: "c", events: [event], accounts: [account], calendars: [calendar, own, group]))
        #expect(try db.guestSuggestions(query: "").map(\.email) == ["coworker@acme.com", "friend@acme.com"])
        #expect(try db.guestSuggestions(query: "FRI").first?.displayName == "Friend")
    }
}
