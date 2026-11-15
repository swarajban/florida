import Testing
@testable import FloridaCore

struct EventGuestEntryTests {
    @Test func preservesMetadataAndOmitsUntouchedGuests() {
        var entry = EventGuestEntry(attendees: [
            EventAttendee(email: "me@acme.com", isSelf: true),
            EventAttendee(email: "alice@acme.com", displayName: "Alice", optional: true),
        ])
        #expect(entry.write(isNew: false) == nil)
        entry.input = "bob@acme.com"
        #expect(entry.write(isNew: false) == [
            EventAttendeeWrite(email: "alice@acme.com", displayName: "Alice", optional: true),
            EventAttendeeWrite(email: "bob@acme.com"),
        ])
        entry.remove("alice@acme.com")
        entry.remove("bob@acme.com")
        #expect(entry.write(isNew: false) == [])
    }

    @Test func combinesParsedGuestsAndCommitsValidPendingInput() {
        var entry = EventGuestEntry()
        entry.input = " ALICE@acme.com, "
        #expect(entry.write(isNew: true, parsed: ["alice@acme.com"]) == [EventAttendeeWrite(email: "alice@acme.com")])
        entry.remove("alice@acme.com")
        #expect(entry.combined(parsed: ["alice@acme.com"]).isEmpty)
        entry.add("alice@acme.com", displayName: "Alice")
        #expect(entry.combined(parsed: ["alice@acme.com"]).count == 1)
        entry.input = "not an email"
        entry.commitInput()
        #expect(entry.input == "not an email")
        #expect(EventGuestEntry().combined().isEmpty)
    }
}
