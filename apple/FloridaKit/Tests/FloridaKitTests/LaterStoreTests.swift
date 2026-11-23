import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct LaterStoreTests {
    @Test func storesAndReplacesCatchUpBlocksWhileKeepingLaterRows() throws {
        let db = try AppDatabase.inMemory()
        let now = Fixtures.t0
        let item = LaterItem(id: "later", url: "https://example.com/story", canonicalUrl: "https://example.com/story",
            title: "Story", site: "Example", kind: .article, estMinutes: 5, savedAt: now, source: .mcp, updatedAt: now, enrichedAt: now)
        let block = CatchUpBlock(id: "2026-11-22", startAt: now, endAt: now.addingTimeInterval(600), items: [
            .init(id: item.id, title: item.title, site: item.site, url: item.url, estMinutes: 5)
        ])
        let settings = UserSettings(id: "default", timeZone: "America/Los_Angeles", updatedAt: now,
            catchUp: .init(enabled: true, minutes: 30, windows: [.init(days: [0], start: "18:00", end: "21:00")]))
        try db.apply(SyncResponse(cursor: "one", settings: settings, laterItems: [item], catchUpBlocks: [block]))
        #expect(try db.planSummary().catchUpBlocks == [block])
        #expect(try db.userSettings() == settings)
        try db.apply(SyncResponse(cursor: "two", settings: settings))
        #expect(try db.planSummary().catchUpBlocks.isEmpty)
        #expect(try db.laterItems() == [item])
    }

    @Test func catchUpMigrationResetsCursorToBackfillExistingEnrichment() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v15-later-items")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO syncState (key, value) VALUES ('cursor', 'already-synced')")
        }
        let db = try AppDatabase(writer: queue)
        #expect(try db.cursor() == nil)
    }

    @Test func upgradeResetsCursorSoPreviouslySavedLinksBackfill() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v14-task-required-day")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO syncState (key, value) VALUES ('cursor', 'old')")
            var write = PendingWrite(entity: .task, entityId: "keep", op: .delete, body: nil, createdAt: Fixtures.t0)
            try write.insert(db)
        }
        let db = try AppDatabase(writer: queue)
        #expect(try db.cursor() == nil)
        #expect(try db.laterItems().isEmpty)
        #expect(try db.pendingWrites().map(\.entityId) == ["keep"])
    }

    @Test func clientWithoutLaterFieldCanStillPull() throws {
        let data = Data(#"{"cursor":"old","schedules":[],"categories":[],"tasks":[],"events":[],"placements":[],"accounts":[],"calendars":[]}"#.utf8)
        #expect(try JSONCoding.decoder.decode(SyncResponse.self, from: data).laterItems.isEmpty)
    }

    @Test func captureCoalescesWithOfflineActionAndPushesWithoutReplacingPlan() async throws {
        let db = try AppDatabase.inMemory()
        let t0 = Fixtures.t0
        let placement = Fixtures.placement(id: "p", taskId: "task",
            start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        try db.apply(SyncResponse(cursor: "c1", tasks: [Fixtures.task(id: "task")], placements: [placement]))
        let captureID = UUID()
        let url = "https://example.com/post#section"
        let item = try db.saveLater(url: url, kind: .article, source: .share, captureID: captureID, now: t0)
        #expect(try db.saveLater(url: url, kind: .article, captureID: captureID) == item)
        #expect(try db.laterItems() == [item])
        #expect(item.canonicalUrl == "https://example.com/post")
        let readTime = t0.addingTimeInterval(120)
        try db.setLaterState(id: item.id, action: .read, now: readTime)
        try db.apply(SyncResponse(cursor: "c2", placements: [placement], laterItems: [item]))
        #expect(try db.laterItems().isEmpty)
        #expect(try db.laterItems(status: .read).first?.readAt == readTime)

        var accepted = item
        accepted.apply(.read, at: readTime)
        accepted.estMinutes = 4
        var requeued = accepted
        requeued.apply(.later, at: readTime.addingTimeInterval(120))
        let transport = FakeTransport([try .ok(accepted), try .ok(requeued), .json(status: 204, body: Data())])
        let client = SyncClient(database: db,
            config: ServerConfig(baseURL: URL(string: "https://example.com")!, token: "test"), transport: transport)
        #expect(try await client.push() == 1)
        let put = try #require(transport.requests.first)
        let putData = try #require(put.body)
        let body = try #require(JSONSerialization.jsonObject(with: putData) as? [String: Any])
        #expect(put.method == "PUT" && put.path == "/api/later/\(item.id)")
        #expect(body["savedAt"] as? String == JSONCoding.formatInstant(t0))
        #expect((body["state"] as? [String: String])?["action"] == "read")
        #expect(try db.laterItems(status: .read) == [accepted])
        #expect(try await db.writer.read { try Placement.fetchOne($0, id: placement.id) } == placement)

        try db.setLaterState(id: item.id, action: .later, now: requeued.updatedAt)
        #expect(try await client.push() == 1)
        #expect(transport.requests.last?.method == "PATCH")
        #expect(try db.laterItems() == [requeued])
        try db.deleteLater(id: item.id)
        #expect(try db.laterItems(status: nil).isEmpty)
        #expect(try await client.push() == 1)
        #expect(transport.requests.last?.method == "DELETE")
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func incomingTombstoneRemovesLocalRow() throws {
        let db = try AppDatabase.inMemory()
        let url = "https://example.com/story"
        var item = LaterItem(id: "later", url: url, canonicalUrl: url, title: "Story", site: "example.com",
            kind: .article, savedAt: Fixtures.t0, source: .mcp, updatedAt: Fixtures.t0)
        try db.apply(SyncResponse(cursor: "initial", laterItems: [item]))
        #expect(try db.laterItems() == [item])
        item.deletedAt = Fixtures.t0
        try db.apply(SyncResponse(cursor: "tombstone", laterItems: [item]))
        #expect(try db.writer.read { try LaterItem.fetchOne($0, id: item.id) } == nil)
    }

    @Test func stateEditAfterDiscardedCreationSendsANewPut() async throws {
        let db = try AppDatabase.inMemory()
        let item = try db.saveLater(url: "https://example.com/story", kind: .article)
        var archived = item
        let now = Fixtures.t0
        archived.apply(.archive, at: now)
        let transport = FakeTransport([.error(404, "Later item not found"), try .ok(archived)])
        let client = SyncClient(database: db,
            config: ServerConfig(baseURL: URL(string: "https://example.com")!, token: "test"), transport: transport)
        try await client.discard(#require(try db.pendingWrites().first))
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.laterItems().map(\.id) == [item.id])
        try db.setLaterState(id: item.id, action: .archive, now: now)
        #expect(try await client.push() == 1)
        #expect(transport.requests.map(\.method) == ["GET", "PUT"])
        #expect(try db.laterItems(status: .archived).map(\.id) == [item.id])
    }

    @Test func deleteAfterRejectedCreationTreatsServerAbsenceAsSuccess() async throws {
        let db = try AppDatabase.inMemory()
        let item = try db.saveLater(url: "https://example.com/story", kind: .article)
        let transport = FakeTransport([.error(400, "rejected"), .error(404, "Later item not found"),
            .error(404, "Later item not found")])
        let client = SyncClient(database: db,
            config: ServerConfig(baseURL: URL(string: "https://example.com")!, token: "test"), transport: transport)
        #expect(try await client.push() == 0)
        #expect(await client.lastRejectedWrites.count == 1)
        try db.deleteLater(id: item.id)
        #expect(try await client.push() == 1)
        #expect(transport.requests.map(\.method) == ["PUT", "GET", "DELETE"])
        #expect(await client.lastRejectedWrites.isEmpty)
        #expect(try await db.writer.read { try LaterItem.fetchOne($0, id: item.id) } == nil)
    }
}
