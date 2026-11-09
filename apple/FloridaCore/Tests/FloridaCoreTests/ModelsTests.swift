import Foundation
import Testing
@testable import FloridaCore

@Suite struct JSONCodingTests {
    @Test func parsesServerInstantsWithAndWithoutFraction() throws {
        let withFraction = try #require(JSONCoding.parseInstant("2026-11-08T17:00:00.250Z"))
        let whole = try #require(JSONCoding.parseInstant("2026-11-08T17:00:00Z"))
        #expect(withFraction.timeIntervalSince(whole) == 0.25)
        let offset = try #require(JSONCoding.parseInstant("2026-11-08T09:00:00-08:00"))
        #expect(offset == whole)
        #expect(JSONCoding.parseInstant("yesterday") == nil)
    }

    @Test func formatsLikeJavaScript() {
        let date = Date(timeIntervalSince1970: 1_794_157_200.5)
        #expect(JSONCoding.formatInstant(date) == "2026-11-08T17:00:00.500Z")
    }

    @Test func decodesSyncResponse() throws {
        let json = """
        {
          "cursor": "2026-11-08T17:00:00.123Z",
          "schedules": [{"id":"work","name":"Work","timeZone":"America/Los_Angeles",
            "windows":[{"days":[1,2,3,4,5],"start":"09:00","end":"17:00"}],
            "createdAt":"2026-11-01T00:00:00.000Z","updatedAt":"2026-11-01T00:00:00.000Z","deletedAt":null}],
          "categories": [],
          "tasks": [{"id":"t1","categoryId":"inbox","title":"Review","notes":null,"durationMinutes":60,
            "minChunkMinutes":null,"priority":"high","deadlineType":"soft","dueAt":"2026-11-10T00:00:00.000Z",
            "startAt":null,"scheduleId":null,"pinnedStart":null,"completedMinutes":0,"completedAt":null,
            "createdAt":"2026-11-08T00:00:00.000Z","updatedAt":"2026-11-08T00:00:00.000Z","deletedAt":null}],
          "events": [],
          "placements": [{"id":"p1","taskId":"t1","startAt":"2026-11-09T17:00:00.000Z","endAt":"2026-11-09T18:00:00.000Z",
            "pinned":false,"computedAt":"2026-11-08T17:00:00.000Z"}],
          "accounts": [],
          "calendars": []
        }
        """
        let response = try JSONCoding.decoder.decode(SyncResponse.self, from: Data(json.utf8))
        #expect(response.cursor == "2026-11-08T17:00:00.123Z")
        #expect(response.schedules.first?.windows.first?.days == [1, 2, 3, 4, 5])
        #expect(response.tasks.first?.priority == .high)
        #expect(response.tasks.first?.isOpen == true)
        #expect(response.placements.first?.endAt.timeIntervalSince(response.placements[0].startAt) == 3600)
    }

    @Test func encodesTaskWriteWithNulls() throws {
        let task = TaskItem(
            id: "t1", categoryId: "inbox", title: "Review", durationMinutes: 60, priority: .asap,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONCoding.encoder.encode(TaskWrite(task))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["priority"] as? String == "asap")
        #expect(object["durationMinutes"] as? Int == 60)
        #expect(object["dueAt"] == nil || object["dueAt"] is NSNull)
    }

    @Test func priorityOrdersAsapFirst() {
        #expect(Priority.allCases.sorted() == [.asap, .high, .medium, .low])
    }
}

@Suite struct EventModelTests {
    static let base = """
        "id":"e1","calendarId":"cal","googleId":"g1","status":"confirmed","summary":"Standup",
        "location":null,"startAt":"2026-11-09T17:00:00.000Z","endAt":"2026-11-09T17:15:00.000Z","allDay":false,
        "transparency":null,"responseStatus":"accepted","htmlLink":null,
        "updatedAt":"2026-11-08T00:00:00.000Z","deletedAt":null
        """

    func decode(_ json: String) throws -> CalendarEvent {
        try JSONCoding.decoder.decode(CalendarEvent.self, from: Data(json.utf8))
    }

    @Test func decodesAnEventFromAnOlderServer() throws {
        let event = try decode("{\(Self.base)}")
        #expect(event.summary == "Standup")
        #expect(event.description == nil && event.conferenceUrl == nil && event.attendees == nil)
        #expect(event.organizer == nil && event.eventType == nil && event.recurringEventId == nil && event.icalUid == nil)
        #expect(event.joinURL == nil)
        #expect(!event.isOutOfOffice)
    }

    @Test func decodesTheNewFields() throws {
        let event = try decode("""
            {\(Self.base),
             "description":"Agenda in doc","conferenceUrl":"https://meet.google.com/abc-defg-hij",
             "attendees":[
               {"email":"me@example.com","displayName":null,"responseStatus":"accepted","organizer":false,"self":true,"optional":false},
               {"email":"boss@example.com","displayName":"Boss","responseStatus":"tentative","organizer":true,"self":false,"optional":true}],
             "organizer":{"email":"boss@example.com","displayName":"Boss","self":false},
             "eventType":"outOfOffice","recurringEventId":"g0","icalUid":"g0@google.com"}
            """)
        #expect(event.attendees == [
            EventAttendee(email: "me@example.com", responseStatus: "accepted", isSelf: true),
            EventAttendee(email: "boss@example.com", displayName: "Boss", responseStatus: "tentative", organizer: true, optional: true),
        ])
        #expect(event.organizer == EventOrganizer(email: "boss@example.com", displayName: "Boss", isSelf: false))
        #expect(event.isOutOfOffice)
        #expect(event.recurringEventId == "g0")
        #expect(event.icalUid == "g0@google.com")
        #expect(event.joinURL?.absoluteString == "https://meet.google.com/abc-defg-hij")

        // "self" is the wire key both ways.
        let encoded = try JSONCoding.encoder.encode(event.organizer)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"self\":false"))
    }

    func event(location: String? = nil, description: String? = nil, conferenceUrl: String? = nil) -> CalendarEvent {
        CalendarEvent(
            id: "e", calendarId: "c", googleId: "g", location: location, description: description,
            conferenceUrl: conferenceUrl, updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func joinURLPrefersTheConferenceURL() {
        let e = event(
            location: "https://us02web.zoom.us/j/123", description: "https://teams.microsoft.com/l/meetup-join/x",
            conferenceUrl: "https://meet.google.com/abc-defg-hij")
        #expect(e.joinURL?.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test func joinURLFindsAMeetLinkInAnHTMLDescription() {
        let e = event(description: """
            See the <a href="https://docs.google.com/document/d/1">doc</a>.<br>Join: \
            <a href="https://meet.google.com/xyz-abcd-efg?authuser=0">https://meet.google.com/xyz-abcd-efg</a>
            """)
        #expect(e.joinURL?.absoluteString == "https://meet.google.com/xyz-abcd-efg?authuser=0")
    }

    @Test func joinURLFindsAZoomLinkInTheLocationBeforeTheDescription() {
        let e = event(
            location: "Room 4 / https://us02web.zoom.us/j/8123456789?pwd=abc.",
            description: "Backup: https://acme.webex.com/meet/bob")
        #expect(e.joinURL?.absoluteString == "https://us02web.zoom.us/j/8123456789?pwd=abc")
    }

    @Test func joinURLIgnoresOtherLinksAndLookalikeHosts() {
        #expect(event().joinURL == nil)
        #expect(event(location: "Café Rouge, 12 Main St").joinURL == nil)
        #expect(event(description: "https://example.com/zoom.us and https://notzoom.us/j/1").joinURL == nil)
        #expect(event(description: "(https://acme.webex.com/meet/bob)").joinURL?.absoluteString == "https://acme.webex.com/meet/bob")
    }

    @Test func inboxIsTheFixedCategoryId() {
        let at = Date(timeIntervalSince1970: 0)
        #expect(TaskCategory(id: TaskCategory.inboxId, name: "Inbox", scheduleId: "s", createdAt: at, updatedAt: at).isInbox)
        #expect(!TaskCategory(id: "work", name: "Inbox", scheduleId: "s", createdAt: at, updatedAt: at).isInbox)
    }

    @Test func syncResponseUnscheduledDefaultsToEmpty() throws {
        let tables = #""schedules":[],"categories":[],"tasks":[],"events":[],"placements":[],"accounts":[],"calendars":[]"#
        let old = try JSONCoding.decoder.decode(SyncResponse.self, from: Data(#"{"cursor":"c",\#(tables)}"#.utf8))
        #expect(old.unscheduled == [])

        let new = try JSONCoding.decoder.decode(SyncResponse.self, from: Data("""
            {"cursor":"c",\(tables),"unscheduled":[
              {"taskId":"t1","reason":"no_fit_before_hard_deadline","unplacedMinutes":45,"computedAt":"2026-11-08T17:00:00.000Z"}]}
            """.utf8))
        #expect(new.unscheduled == [UnscheduledTask(
            taskId: "t1", reason: "no_fit_before_hard_deadline", unplacedMinutes: 45,
            computedAt: JSONCoding.parseInstant("2026-11-08T17:00:00Z")!)])
        #expect(new.unscheduled.first?.id == "t1")
    }

    @Test func decodesATaskDraftWithOffsetInstants() throws {
        let draft = try JSONCoding.decoder.decode(TaskDraft.self, from: Data("""
            {"title":"Send invoice","notes":null,"durationMinutes":30,"minChunkMinutes":null,"priority":"high",
             "deadlineType":"hard","dueAt":"2026-11-13T17:00:00-08:00","startAt":null,"pinnedStart":null,
             "categoryId":"work","rationale":"Due Friday at 5pm."}
            """.utf8))
        #expect(draft.priority == .high)
        #expect(draft.deadlineType == .hard)
        #expect(draft.dueAt == JSONCoding.parseInstant("2026-11-14T01:00:00Z"))
        #expect(draft.categoryId == "work")
    }
}
