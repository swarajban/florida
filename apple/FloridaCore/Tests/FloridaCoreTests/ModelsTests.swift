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
          "projects": [],
          "tasks": [{"id":"t1","projectId":"inbox","title":"Review","notes":null,"durationMinutes":60,
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
            id: "t1", projectId: "inbox", title: "Review", durationMinutes: 60, priority: .asap,
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
