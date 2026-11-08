import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloridaKit

@Suite struct SyncClientCalendarsTests {
    let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "secret-token")

    @Test func patchesTheCalendarAndAppliesTheSchedulerResult() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(
            cursor: "c1",
            projects: [Fixtures.project()],
            tasks: [Fixtures.task(id: "t1")],
            placements: [Fixtures.placement(id: "old", taskId: "t1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z")],
            accounts: [Fixtures.account()],
            calendars: [Fixtures.calendar(id: "cal", selected: true)]))

        let serverReply = Data("""
            {"calendar":{"id":"cal","googleId":"g-cal","selected":false},
             "scheduling":{"placements":[{"taskId":"t1","start":"2026-11-10T17:00:00.000Z","end":"2026-11-10T18:00:00.000Z","pinned":false}],
                           "unscheduled":[],"late":[]}}
            """.utf8)
        let transport = FakeTransport([.ok(serverReply)])
        let client = SyncClient(database: db, config: config, transport: transport)

        try await client.setCalendarSelected(id: "cal", selected: false)

        let requests = transport.requests
        try #require(requests.count == 1)
        #expect(requests[0].method == "PATCH")
        #expect(requests[0].path == "/api/calendars/cal")
        #expect(requests[0].headers["Authorization"] == "Bearer secret-token")
        #expect(requests[0].headers["Content-Type"] == "application/json")
        let body = try JSONSerialization.jsonObject(with: try #require(requests[0].body)) as? [String: Bool]
        #expect(body == ["selected": false])

        #expect(try db.calendars().map(\.selected) == [false])
        let placements = try db.placements(in: Fixtures.allTime)
        #expect(placements.map(\.startAt) == [Fixtures.instant("2026-11-10T17:00:00Z")])
    }

    @Test func serverErrorsLeaveTheLocalFlagAlone() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c1", calendars: [Fixtures.calendar(id: "cal", selected: true)]))
        let transport = FakeTransport([.error(404, "calendar cal not found")])
        let client = SyncClient(database: db, config: config, transport: transport)

        await #expect(throws: SyncError.self) {
            try await client.setCalendarSelected(id: "cal", selected: false)
        }
        #expect(try db.calendars().map(\.selected) == [true])
    }

    @Test func localFlagCanBeSetAheadOfTheServer() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c1", calendars: [Fixtures.calendar(id: "cal", selected: true)]))
        try db.setCalendarSelected(id: "cal", selected: false, now: Fixtures.instant("2026-11-08T12:00:00Z"))
        let calendar = try #require(try db.calendars().first)
        #expect(calendar.selected == false)
        #expect(calendar.updatedAt == Fixtures.instant("2026-11-08T12:00:00Z"))
        // Events from an unselected calendar stop being visible.
        #expect(try db.events(in: Fixtures.allTime).isEmpty)
    }
}
