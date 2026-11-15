import Foundation
import Testing
@testable import FloridaCore

struct EventGuestTests {
    @Test func writeEncodingDistinguishesOmissionFromRemoval() throws {
        var write = EventWrite(calendarId: "cal", summary: "Meeting", startAt: Date(), endAt: Date(), allDay: false)
        func json() throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(write)) as? [String: Any])
        }
        #expect(try json()["attendees"] == nil)
        write.attendees = []
        #expect(try (json()["attendees"] as? [Any])?.isEmpty == true)
        write.attendees = [EventAttendeeWrite(email: "a@acme.com", displayName: "Alice", optional: true)]
        let guests = try #require(try json()["attendees"] as? [[String: Any]])
        #expect(guests[0]["email"] as? String == "a@acme.com")
        #expect(guests[0]["displayName"] as? String == "Alice")
        #expect(guests[0]["optional"] as? Bool == true)
        #expect(try JSONDecoder().decode(EventWrite.self, from: JSONEncoder().encode(write)) == write)
        #expect(try JSONDecoder().decode(EventAttendeeWrite.self, from: Data(#"{"email":"a@acme.com"}"#.utf8)) == EventAttendeeWrite(email: "a@acme.com"))
    }

    @Test(arguments: [
        "Review with ALICE@acme.com, bob@acme.com tomorrow at 3pm",
        "Review with alice@acme.com and bob@acme.com tomorrow at 3pm",
        "Review alice@acme.com bob@acme.com ALICE@acme.com tomorrow at 3pm",
        "Review with alice@acme.com,bob@acme.com tomorrow at 3pm",
    ])
    func extractsEmailsWithoutPollutingTitle(_ text: String) {
        let parsed = EventQuickAddParser.parse(text, now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian))
        #expect(parsed.title == "Review")
        #expect(parsed.attendees == ["alice@acme.com", "bob@acme.com"])
    }

    @Test func keepsNamesInvalidEmailsAndNotes() {
        let parsed = EventQuickAddParser.parse("Lunch with Dana bad@email // ask alice@acme.com", now: Date(), calendar: .current)
        #expect(parsed.title == "Lunch with Dana bad@email")
        #expect(parsed.attendees.isEmpty)
        #expect(parsed.notes == "ask alice@acme.com")
    }

    @Test func suggestionsRankMatchBeforeFrequencyAndFilterOwnAndGroupAddresses() {
        let now = Date()
        let account = GoogleAccount(id: "a", email: "ME@acme.com", label: "work", updatedAt: now)
        func calendar(_ email: String, _ name: String) -> CalendarInfo {
            CalendarInfo(id: email, accountId: "a", googleId: email, summary: name, accessRole: "reader", selected: false, updatedAt: now)
        }
        let calendars = [calendar("ME@acme.com", "Me"), calendar("team@group.calendar.google.com", "Group"),
                         calendar("coworker@acme.com", "Alice Coworker")]
        let history = [EventAttendee(email: "frequent@acme.com", displayName: "Malice"),
                       EventAttendee(email: "frequent@acme.com"), EventAttendee(email: "frequent@acme.com"),
                       EventAttendee(email: "self@acme.com", isSelf: true), EventAttendee(email: "invalid")]
        let matches = GuestSuggestion.ranked(query: "alice", calendars: calendars, accounts: [account], attendees: history)
        #expect(matches.map(\.email) == ["coworker@acme.com", "frequent@acme.com"])
        let all = GuestSuggestion.ranked(query: "", calendars: calendars, accounts: [account], attendees: history)
        #expect(all.map(\.email) == ["frequent@acme.com", "coworker@acme.com"])
        #expect(GuestSuggestion.ranked(query: "nothing", calendars: calendars, accounts: [account], attendees: history).isEmpty)
    }
}
