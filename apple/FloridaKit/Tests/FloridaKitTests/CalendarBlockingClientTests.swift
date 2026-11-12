import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloridaKit

@Suite struct CalendarBlockingClientTests {
    let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test-token")

    @Test(arguments: [false, true], [false, true])
    func patchesOnlyBlockingAndAppliesScheduling(selected: Bool, blocksScheduling: Bool) async throws {
        let db = try AppDatabase.inMemory()
        var calendar = Fixtures.calendar(selected: selected)
        calendar.blocksScheduling = !blocksScheduling
        try db.apply(SyncResponse(
            cursor: "c1", tasks: [Fixtures.task(id: "t1")],
            placements: [Fixtures.placement(id: "old", taskId: "t1", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z")],
            calendars: [calendar]))
        let reply = Data("""
            {"ok":true,"scheduling":{
              "placements":[{"taskId":"t1","start":"2026-11-10T17:00:00Z","end":"2026-11-10T18:00:00Z","pinned":false}],
              "unscheduled":[],"late":[]}}
            """.utf8)
        let transport = FakeTransport([.ok(reply)])
        let client = SyncClient(database: db, config: config, transport: transport)

        try await client.setCalendarBlocksScheduling(id: "cal", blocksScheduling: blocksScheduling)

        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/calendars/cal")
        #expect(request.headers["Authorization"] == "Bearer test-token")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: Bool]
        #expect(body == ["blocksScheduling": blocksScheduling])
        let stored = try #require(try db.calendars().first)
        #expect(stored.selected == selected)
        #expect(stored.blocksScheduling == blocksScheduling)
        #expect(try db.placements(in: Fixtures.allTime).map(\.startAt) == [Fixtures.instant("2026-11-10T17:00:00Z")])
    }

    @Test func visibilityPatchDoesNotChangeBlocking() async throws {
        let db = try AppDatabase.inMemory()
        var calendar = Fixtures.calendar()
        calendar.blocksScheduling = false
        try db.apply(SyncResponse(cursor: "c1", calendars: [calendar]))
        let transport = FakeTransport([.ok(Data(#"{"ok":true,"scheduling":{"placements":[],"unscheduled":[],"late":[]}}"#.utf8))])
        let client = SyncClient(database: db, config: config, transport: transport)

        try await client.setCalendarSelected(id: "cal", selected: false)

        let request = try #require(transport.requests.first)
        let body = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: Bool]
        #expect(body == ["selected": false])
        #expect(try db.calendars().first?.selected == false)
        #expect(try db.calendars().first?.blocksScheduling == false)
    }

    @Test func failedRequestKeepsTheOptimisticLocalEdit() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c1", calendars: [Fixtures.calendar()]))
        try db.setCalendarBlocksScheduling(id: "cal", blocksScheduling: false)
        let transport = FakeTransport([.failure(NetworkDown())])
        let client = SyncClient(database: db, config: config, transport: transport)

        await #expect(throws: SyncError.self) {
            try await client.setCalendarBlocksScheduling(id: "cal", blocksScheduling: false)
        }
        #expect(try db.calendars().first?.blocksScheduling == false)
        #expect(try db.calendars().first?.selected == true)
    }
}
