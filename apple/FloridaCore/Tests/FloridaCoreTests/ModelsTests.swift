import Foundation
import Testing
@testable import FloridaCore

@Suite struct JSONCodingTests {
    @Test func newEventCalendarPreferenceOverridesAlphabeticalAndVisibilityOrder() {
        let accounts = [
            GoogleAccount(id: "work", email: "me@sempre-health.com", label: "work", updatedAt: .distantPast),
            GoogleAccount(id: "personal", email: "me@gmail.com", label: "personal", updatedAt: .distantPast),
        ]
        func calendar(_ id: String, _ name: String, googleId: String? = nil, selected: Bool = true) -> CalendarInfo {
            CalendarInfo(id: id, accountId: "work", googleId: googleId ?? id, summary: name, accessRole: "owner", selected: selected, updatedAt: .distantPast)
        }
        let calendars = [
            calendar("other", "AAA"), calendar("family", "A&S Family Calendar"),
            calendar("colleague", "coworker@sempre-health.com", googleId: "coworker@sempre-health.com"),
            calendar("personal", "me@gmail.com", googleId: "me@gmail.com"),
            calendar("sempre", "Renamed work calendar", googleId: "ME@sempre-health.com", selected: false),
        ]
        let preferred = { CalendarInfo.isPreferredForNewEvents($0, $1, accounts: accounts) }
        #expect(calendars.sorted(by: preferred).map(\.id) == ["sempre", "personal", "family", "other", "colleague"])
        #expect(calendars.filter { $0.id != "sempre" }.sorted(by: preferred).first?.id == "personal")
        #expect(calendars.prefix(2).sorted(by: preferred).first?.id == "family")
        #expect([calendar("p", "PERSONAL"), calendar("s", " sempre ")].sorted(by: preferred).map(\.id) == ["s", "p"])
    }

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
        #expect(response.tasks.first?.recurrenceRevision == nil, "older servers omit the revision")
        #expect(response.tasks.first?.context == .computer, "older servers omit the context")
        #expect(response.settings == nil)
        #expect(response.routineBlocks == [])
        #expect(response.optionalPlacements == [], "older servers have no suggestions")
        #expect(response.placements.first?.endAt.timeIntervalSince(response.placements[0].startAt) == 3600)
    }

    @Test func decodesTheRoutineSettingsContextAndArea() throws {
        let stamps = #""createdAt":"2026-11-01T00:00:00.000Z","updatedAt":"2026-11-01T00:00:00.000Z","deletedAt":null"#
        let json = """
        {
          "cursor": "c",
          "settings": {"id":"me","timeZone":"America/Los_Angeles","updatedAt":"2026-11-01T00:00:00.000Z"},
          "routineBlocks": [{"id":"office-tue","name":"Office","days":[2],"start":"10:15","end":"16:20",
            "allows":["computer","office"],\(stamps)}],
          "schedules": [],
          "categories": [
            {"id":"eng","name":"Engineering","color":null,"area":"work","scheduleId":"work","sortOrder":1,\(stamps)},
            {"id":"inbox","name":"Inbox","color":null,"area":null,"scheduleId":"work","sortOrder":0,\(stamps)}],
          "tasks": [{"id":"t1","categoryId":"inbox","title":"UPS return","notes":null,"durationMinutes":30,
            "minChunkMinutes":null,"priority":"medium","deadlineType":"none","dueAt":null,"startAt":null,
            "scheduleId":null,"context":"errand","pinnedStart":null,"completedMinutes":0,"completedAt":null,\(stamps)}],
          "events": [], "placements": [], "accounts": [], "calendars": []
        }
        """
        let response = try JSONCoding.decoder.decode(SyncResponse.self, from: Data(json.utf8))
        let at = try #require(JSONCoding.parseInstant("2026-11-01T00:00:00Z"))
        #expect(response.settings == UserSettings(id: "me", timeZone: "America/Los_Angeles", updatedAt: at))
        #expect(response.routineBlocks == [RoutineBlock(
            id: "office-tue", name: "Office", days: [2], start: "10:15", end: "16:20",
            allows: [.computer, .office], createdAt: at, updatedAt: at)])
        #expect(response.categories.map { $0.area } == [.work, nil])
        #expect(response.tasks.first?.context == .errand)
    }

    @Test func decodesOptionalBlocksAndTheirSuggestions() throws {
        let stamps = #""createdAt":"2026-11-01T00:00:00.000Z","updatedAt":"2026-11-01T00:00:00.000Z","deletedAt":null"#
        let json = """
        {
          "cursor": "c",
          "routineBlocks": [
            {"id":"evening","name":"Evening","days":[1,2,3,4],"start":"20:00","end":"23:00",
             "allows":["computer","home"],"optional":true,\(stamps)},
            {"id":"home","name":"Home","days":[1],"start":"09:00","end":"15:30","allows":["computer"],\(stamps)}],
          "schedules": [], "categories": [], "tasks": [], "events": [], "placements": [],
          "optionalPlacements": [{"id":"o1","taskId":"t1","blockId":"evening",
            "startAt":"2026-11-10T04:00:00.000Z","endAt":"2026-11-10T05:30:00.000Z","computedAt":"2026-11-09T17:00:00.000Z"}],
          "accounts": [], "calendars": []
        }
        """
        let response = try JSONCoding.decoder.decode(SyncResponse.self, from: Data(json.utf8))
        #expect(response.routineBlocks.map(\.optional) == [true, false], "a block without the key is planned time")
        #expect(response.optionalPlacements == [OptionalPlacement(
            id: "o1", taskId: "t1", blockId: "evening",
            startAt: try #require(JSONCoding.parseInstant("2026-11-10T04:00:00Z")),
            endAt: try #require(JSONCoding.parseInstant("2026-11-10T05:30:00Z")),
            computedAt: try #require(JSONCoding.parseInstant("2026-11-09T17:00:00Z")))])
    }

    @Test func schedulingResultCarriesSuggestionsApartFromThePlan() throws {
        let old = try JSONCoding.decoder.decode(
            SchedulingResult.self, from: Data(#"{"placements":[],"unscheduled":[],"late":[]}"#.utf8))
        #expect(old.optional == [], "older servers omit the key")

        let result = try JSONCoding.decoder.decode(SchedulingResult.self, from: Data("""
            {"placements":[{"taskId":"t1","start":"2026-11-10T17:00:00.000Z","end":"2026-11-10T18:00:00.000Z","pinned":false}],
             "unscheduled":[],"late":[],
             "optional":[{"taskId":"t1","blockId":"evening","start":"2026-11-10T04:00:00.000Z","end":"2026-11-10T05:00:00.000Z"}]}
            """.utf8))
        let at = Date(timeIntervalSince1970: 0)
        #expect(result.placementRows(computedAt: at).count == 1, "a suggestion is not a placement")
        #expect(result.optionalPlacementRows(computedAt: at, makeId: { "id" }) == [OptionalPlacement(
            id: "id", taskId: "t1", blockId: "evening",
            startAt: try #require(JSONCoding.parseInstant("2026-11-10T04:00:00Z")),
            endAt: try #require(JSONCoding.parseInstant("2026-11-10T05:00:00Z")), computedAt: at)])
    }

    @Test func categoryWriteSendsItsAreaAndOmitsAMissingOne() throws {
        let at = Date(timeIntervalSince1970: 0)
        func body(area: CategoryArea?) throws -> [String: Any] {
            let category = TaskCategory(id: "c", name: "Taxes", area: area, scheduleId: "s", createdAt: at, updatedAt: at)
            let data = try JSONCoding.encoder.encode(CategoryWrite(category))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try body(area: .personal)["area"] as? String == "personal")
        #expect(try body(area: nil)["area"] == nil, "a null would erase the area stored on the server")
    }

    @Test func encodesTaskWriteWithNulls() throws {
        let task = TaskItem(
            id: "t1", categoryId: "inbox", title: "Review", durationMinutes: 60, priority: .asap,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONCoding.encoder.encode(TaskWrite(task))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["priority"] as? String == "asap")
        #expect(object["durationMinutes"] as? Int == 60)
        #expect(object["context"] as? String == "computer")
        #expect(object["recurrence"] is NSNull, "nil explicitly disables recurrence")
        #expect(object["expectedRecurrenceRevision"] is NSNull, "nil is an explicit concurrency baseline")
        #expect(object["recurrenceRevision"] == nil)
        for key in ["notes", "minChunkMinutes", "dueAt", "startAt", "scheduleId", "pinnedStart", "completedAt"] {
            #expect(object[key] == nil, "other nullable fields retain their omission behavior: \(key)")
        }
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

    @Test func joinURLDropsHTMLEntityRemnantsGluedToTheLink() {
        #expect(event(description: "Join: https://zoom.us/j/123&nbsp;(backup below)").joinURL?.absoluteString == "https://zoom.us/j/123")
        #expect(event(description: "<p>https://meet.google.com/abc-defg-hij&#160;</p>").joinURL?.absoluteString
            == "https://meet.google.com/abc-defg-hij")
        // An escaped ampersand inside the query is not a remnant.
        #expect(event(description: "https://us02web.zoom.us/j/1?pwd=a&amp;b=2 now").joinURL?.absoluteString
            == "https://us02web.zoom.us/j/1?pwd=a&amp;b=2")
    }

    @Test func encodesEventWriteWithISOInstantsAndOmitsNilOptionals() throws {
        let start = try #require(JSONCoding.parseInstant("2026-11-09T17:00:00Z"))
        let write = EventWrite(
            calendarId: "cal", summary: "Standup", startAt: start, endAt: start.addingTimeInterval(900),
            allDay: false, responseStatus: "tentative")
        let data = try JSONCoding.encoder.encode(write)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["calendarId", "summary", "startAt", "endAt", "allDay", "responseStatus"])
        #expect(object["calendarId"] as? String == "cal")
        #expect(object["summary"] as? String == "Standup")
        #expect(object["startAt"] as? String == "2026-11-09T17:00:00.000Z")
        #expect(object["endAt"] as? String == "2026-11-09T17:15:00.000Z")
        #expect(object["allDay"] as? Bool == false)
        #expect(object["responseStatus"] as? String == "tentative")
        #expect(try JSONCoding.decoder.decode(EventWrite.self, from: data) == write)

        // A move of the whole series says so; the server reads "series".
        var series = write
        series.scope = .series
        let seriesData = try JSONCoding.encoder.encode(series)
        let seriesObject = try #require(JSONSerialization.jsonObject(with: seriesData) as? [String: Any])
        #expect(seriesObject["scope"] as? String == "series")
        #expect(seriesObject.count == object.count + 1)
        #expect(try JSONCoding.decoder.decode(EventWrite.self, from: seriesData) == series)
    }

    @Test func eventRecurrenceUsesTheCreationWireContract() throws {
        let data = Data("""
            {"calendarId":"cal","summary":"Planning","startAt":"2026-11-09T17:00:00Z","endAt":"2026-11-09T18:00:00Z",
             "allDay":false,"recurrence":{"frequency":"weekly","interval":2,"timeZone":"America/Los_Angeles","count":12}}
            """.utf8)
        let write = try JSONCoding.decoder.decode(EventWrite.self, from: data)
        #expect(write.recurrence == EventRecurrence(frequency: .weekly, interval: 2, timeZone: "America/Los_Angeles", count: 12))
        let encoded = try JSONCoding.encoder.encode(write)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rule = try #require(object["recurrence"] as? [String: Any])
        #expect(rule["frequency"] as? String == "weekly")
        #expect(rule["interval"] as? Int == 2)
        #expect(rule["count"] as? Int == 12)
        #expect(rule["timeZone"] as? String == "America/Los_Angeles")
    }

    @Test func eventWriteOfARowCarriesItsEditableFieldsOnly() throws {
        let start = try #require(JSONCoding.parseInstant("2026-11-10T00:00:00Z"))
        let end = start.addingTimeInterval(86_400)
        let event = CalendarEvent(
            id: "e1", calendarId: "cal", googleId: "g1", summary: "Offsite", location: "Tahoe", startAt: start, endAt: end,
            allDay: true, responseStatus: "accepted", htmlLink: "https://calendar.google.com/x", description: "Pack warm",
            eventType: "default", updatedAt: Date(timeIntervalSince1970: 0))
        let write = try #require(EventWrite(event))
        #expect(write == EventWrite(
            calendarId: "cal", summary: "Offsite", location: "Tahoe", description: "Pack warm", startAt: start, endAt: end,
            allDay: true, responseStatus: "accepted"))
        let object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(write)) as? [String: Any])
        #expect(object["htmlLink"] == nil && object["googleId"] == nil && object["id"] == nil)
        #expect(object["allDay"] as? Bool == true)
        #expect(object["startAt"] as? String == "2026-11-10T00:00:00.000Z")

        // A row without a summary is sent with an empty one, never dropped.
        let bare = CalendarEvent(id: "e2", calendarId: "cal", googleId: "", startAt: start, endAt: end, updatedAt: start)
        let bareWrite = try #require(EventWrite(bare))
        #expect(bareWrite.summary == "")
        #expect(bareWrite.responseStatus == nil)

        // A row missing either time has no valid body: the server requires both.
        #expect(EventWrite(CalendarEvent(id: "e3", calendarId: "cal", googleId: "g3", endAt: end, updatedAt: start)) == nil)
        #expect(EventWrite(CalendarEvent(id: "e4", calendarId: "cal", googleId: "g4", startAt: start, updatedAt: start)) == nil)
    }

    @Test func decodesEventWriteResponse() throws {
        let response = try JSONCoding.decoder.decode(EventWriteResponse.self, from: Data("""
            {"event":{\(Self.base)},"scheduling":{"placements":[{"taskId":"t1","start":"2026-11-09T18:00:00.000Z",
             "end":"2026-11-09T19:00:00.000Z","pinned":false}],"unscheduled":[],"late":[]}}
            """.utf8))
        #expect(response.event.id == "e1" && response.event.summary == "Standup")
        #expect(response.scheduling.placements.map(\.taskId) == ["t1"])
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

@Suite struct ProjectModelTests {
    let at = JSONCoding.parseInstant("2026-11-01T00:00:00Z")!
    let stamps = #""createdAt":"2026-11-01T00:00:00.000Z","updatedAt":"2026-11-01T00:00:00.000Z""#
    let tables = #""schedules":[],"categories":[],"events":[],"accounts":[],"calendars":[]"#

    @Test func decodesProjectsLanesCommitmentsAndBriefsFromSync() throws {
        let json = """
        {"cursor":"c",\(tables),
          "routineBlocks":[{"id":"gym","name":"Gym","days":[2],"start":"09:00","end":"10:15","allows":[],
            "alternates":[{"day":3,"start":"09:00","end":"10:15"}],\(stamps),"deletedAt":null}],
          "projects":[{"id":"florida","name":"Florida","status":"on_hold","categoryId":null,"notes":null,
            "nextStep":"Ship lanes","parallel":true,"weeklyMinutes":120,"sortOrder":2,\(stamps),"deletedAt":null}],
          "dayOverrides":[{"date":"2026-11-12","kind":"office","note":"offsite",\(stamps),"deletedAt":null}],
          "tasks":[{"id":"t1","categoryId":"inbox","title":"Lanes","notes":null,"durationMinutes":60,
            "minChunkMinutes":null,"priority":"medium","deadlineType":"none","dueAt":null,"startAt":null,
            "scheduleId":null,"context":"computer","projectId":"florida","attention":"shared","pinnedStart":null,
            "completedMinutes":0,"completedAt":null,\(stamps),"deletedAt":null}],
          "placements":[{"id":"p1","taskId":"t1","startAt":"2026-11-09T17:00:00.000Z","endAt":"2026-11-09T18:00:00.000Z",
            "pinned":false,"lane":1,"computedAt":"2026-11-01T00:00:00.000Z"}],
          "projectPlacements":[{"id":"pp1","projectId":"florida","weekOf":"2026-11-08",
            "startAt":"2026-11-09T18:00:00.000Z","endAt":"2026-11-09T19:00:00.000Z","lane":null,
            "computedAt":"2026-11-01T00:00:00.000Z"}],
          "routineOccurrences":[{"id":"o1","blockId":"gym","startAt":"2026-11-10T17:00:00.000Z",
            "endAt":"2026-11-10T18:15:00.000Z","computedAt":"2026-11-01T00:00:00.000Z"}],
          "missed":[{"blockId":"gym","weekOf":"2026-11-15"}],
          "capacity":[{"date":"2026-11-09","freeMinutes":{"computer":240,"errand":30,"home":0,"office":15}}],
          "briefs":[{"id":"b1","kind":"weekly","date":"2026-11-08","headline":"A full week","body":"Three lanes.",\(stamps)}]
        }
        """
        let response = try JSONCoding.decoder.decode(SyncResponse.self, from: Data(json.utf8))

        let gym = try #require(response.routineBlocks.first)
        #expect(gym.isCommitment)
        #expect(gym.alternates == [RoutineSlot(day: 3, start: "09:00", end: "10:15")])
        #expect(response.projects == [Project(
            id: "florida", name: "Florida", status: .onHold, nextStep: "Ship lanes", parallel: true, weeklyMinutes: 120,
            sortOrder: 2, createdAt: at, updatedAt: at)])
        #expect(response.dayOverrides == [DayOverride(date: "2026-11-12", kind: .office, note: "offsite", createdAt: at, updatedAt: at)])
        #expect(response.dayOverrides.first?.id == "2026-11-12")
        #expect(response.tasks.first?.projectId == "florida")
        #expect(response.tasks.first?.attention == .shared)
        #expect(response.placements.first?.lane == 1)
        #expect(response.projectPlacements.first?.weekOf == "2026-11-08")
        #expect(response.projectPlacements.first?.lane == nil)
        #expect(response.routineOccurrences.first?.blockId == "gym")
        #expect(response.planSummary == PlanSummary(
            missed: [MissedCommitment(blockId: "gym", weekOf: "2026-11-15")],
            capacity: [DayCapacity(date: "2026-11-09", freeMinutes: .init(computer: 240, errand: 30, home: 0, office: 15))]))
        #expect(response.capacity.first?.freeMinutes[.errand] == 30)
        #expect(response.briefs.first?.kind == .weekly)
        #expect(response.briefs.first?.headline == "A full week")
    }

    @Test func aServerWithoutProjectsStillDecodes() throws {
        // What production answers until the projects server is deployed: none of the new keys.
        let old = #"{"cursor":"c",\#(tables),"placements":[{"id":"p1","taskId":"t1","startAt":"2026-11-09T17:00:00.000Z","#
            + #""endAt":"2026-11-09T18:00:00.000Z","pinned":false,"computedAt":"2026-11-01T00:00:00.000Z"}],"#
            + #""tasks":[{"id":"t1","categoryId":"inbox","title":"Old","notes":null,"durationMinutes":60,"#
            + #""minChunkMinutes":null,"priority":"medium","deadlineType":"none","dueAt":null,"startAt":null,"#
            + #""scheduleId":null,"pinnedStart":null,"completedMinutes":0,"completedAt":null,\#(stamps)}]}"#
        let response = try JSONCoding.decoder.decode(SyncResponse.self, from: Data(old.utf8))
        #expect(response.projects.isEmpty && response.dayOverrides.isEmpty && response.briefs.isEmpty)
        #expect(response.projectPlacements.isEmpty && response.routineOccurrences.isEmpty)
        #expect(response.planSummary == PlanSummary())
        #expect(response.tasks.first?.projectId == nil && response.tasks.first?.attention == nil)
        #expect(response.placements.first?.lane == nil)

        let result = try JSONCoding.decoder.decode(
            SchedulingResult.self, from: Data(#"{"placements":[],"unscheduled":[],"late":[]}"#.utf8))
        #expect(result == SchedulingResult())
    }

    @Test func schedulingResultCarriesLanesProjectTimeAndCommitments() throws {
        let json = """
        {"placements":[{"taskId":"t1","start":"2026-11-09T17:00:00.000Z","end":"2026-11-09T18:00:00.000Z","pinned":false,"lane":2}],
         "unscheduled":[],"late":[],"optional":[],
         "routine":[{"blockId":"gym","start":"2026-11-10T17:00:00.000Z","end":"2026-11-10T18:15:00.000Z"}],
         "missed":[{"blockId":"gym","weekOf":"2026-11-15"}],
         "capacity":[{"date":"2026-11-09","freeMinutes":{"computer":60,"errand":0,"home":0,"office":0}}],
         "projectPlacements":[{"projectId":"florida","weekOf":"2026-11-08","start":"2026-11-09T18:00:00.000Z",
           "end":"2026-11-09T19:00:00.000Z","lane":0}]}
        """
        let result = try JSONCoding.decoder.decode(SchedulingResult.self, from: Data(json.utf8))
        var ids = ["a", "b", "c"].makeIterator()
        let nextId = { ids.next() ?? "?" }

        #expect(result.placementRows(computedAt: at, makeId: nextId).map(\.lane) == [2])
        let held = try #require(result.projectPlacementRows(computedAt: at, makeId: nextId).first)
        #expect(held == ProjectPlacement(
            id: "b", projectId: "florida", weekOf: "2026-11-08",
            startAt: JSONCoding.parseInstant("2026-11-09T18:00:00Z")!, endAt: JSONCoding.parseInstant("2026-11-09T19:00:00Z")!,
            lane: 0, computedAt: at))
        let gym = try #require(result.routineOccurrenceRows(computedAt: at, makeId: nextId).first)
        #expect(gym.id == "c" && gym.blockId == "gym")
        #expect(gym.endAt == JSONCoding.parseInstant("2026-11-10T18:15:00Z"))
        #expect(result.planSummary.missed == [MissedCommitment(blockId: "gym", weekOf: "2026-11-15")])
        #expect(result.planSummary.capacity.first?.freeMinutes[.computer] == 60)
    }

    @Test func taskWriteLeavesOutAnUnsetProjectAndAttentionAndSendsSetOnes() throws {
        var task = TaskItem(id: "t1", categoryId: "inbox", title: "Lanes", durationMinutes: 60, priority: .medium, createdAt: at, updatedAt: at)
        var object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(TaskWrite(task))) as? [String: Any])
        #expect(object["projectId"] == nil && object["attention"] == nil, "a missing key keeps the server's value")

        task.projectId = "florida"
        task.attention = .shared
        object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(TaskWrite(task))) as? [String: Any])
        #expect(object["projectId"] as? String == "florida")
        #expect(object["attention"] as? String == "shared")
    }

    @Test func projectWriteSendsTheStatusOnTheWireAndOmitsClearedFields() throws {
        let project = Project(id: "florida", name: "Florida", status: .onHold, parallel: true, sortOrder: 3, createdAt: at, updatedAt: at)
        let object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(ProjectWrite(project))) as? [String: Any])
        #expect(object["status"] as? String == "on_hold")
        #expect(object["parallel"] as? Bool == true)
        #expect(object["sortOrder"] as? Int == 3)
        #expect(object["id"] == nil && object["updatedAt"] == nil)
        for key in ["categoryId", "notes", "nextStep", "weeklyMinutes"] {
            #expect(object[key] == nil, "a cleared field is left out: \(key)")
        }
    }

    @Test func aTaskFollowsItsProjectsAttentionUnlessItSaysOtherwiseOrIsPinned() {
        let parallel = Project(id: "p", name: "P", parallel: true, createdAt: at, updatedAt: at)
        let solo = Project(id: "s", name: "S", createdAt: at, updatedAt: at)
        var task = TaskItem(id: "t1", categoryId: "inbox", title: "x", durationMinutes: 60, priority: .medium, createdAt: at, updatedAt: at)

        #expect(task.attention(in: nil) == .full)
        #expect(task.attention(in: solo) == .full)
        #expect(task.attention(in: parallel) == .shared)
        task.attention = .full
        #expect(task.attention(in: parallel) == .full)
        task.attention = .shared
        #expect(task.attention(in: solo) == .shared)
        task.pinnedStart = at
        #expect(task.attention(in: parallel) == .full, "a pinned task has its time to itself")
    }
}
