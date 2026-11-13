import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloridaKit

private actor GatedRecurringTransport: HTTPTransport {
    var task: TaskItem
    var revisions: [String] = []
    var firstRequest: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?

    init(task: TaskItem) { self.task = task }

    func waitUntilStarted() async {
        if firstRequest != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func releaseFirst() {
        firstRequest?.resume()
        firstRequest = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if request.httpMethod == "GET" {
            return (try JSONCoding.encoder.encode(task), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let data = try #require(request.httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let revision = fields["expectedRecurrenceRevision"] as? String ?? "null"
        revisions.append(revision)
        if revisions.count == 1 {
            await withCheckedContinuation { continuation in
                firstRequest = continuation
                started?.resume()
                started = nil
            }
            task.recurrenceRevision = "r2"
        } else if revision != "r2" {
            return (Data(#"{"error":"recurrence changed"}"#.utf8), HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        } else {
            task.notes = fields["notes"] as? String
            task.recurrenceRevision = "r3"
        }
        return (try Fixtures.putResponse("task", task), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct LocalWritePushRaceTests {
    @Test func overlappingPushesWaitForTheAcceptedRecurrenceRevision() async throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "recurring")
        task.recurrence = TaskRecurrence(frequency: .week, interval: 1, timeZone: "UTC", startDate: "2026-11-08")
        task.recurrenceSeriesId = "series"
        task.recurrenceDate = "2026-11-08"
        task.recurrenceRevision = "r1"
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        task.title = "First edit"
        try db.saveTask(task)
        let transport = GatedRecurringTransport(task: task)
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        let first = Task { try await client.push() }
        await transport.waitUntilStarted()
        task.notes = "Second edit during HTTP"
        try db.saveTask(task)
        let second = Task { try await client.push() }
        try await Task.sleep(for: .milliseconds(100))
        await transport.releaseFirst()
        #expect(try await first.value == 1)
        #expect(try await second.value == 1)
        #expect(await transport.revisions == ["r1", "r2"])
        #expect(try db.task(id: task.id)?.notes == task.notes)
        #expect(try db.task(id: task.id)?.recurrenceRevision == "r3")
        #expect(try db.pendingWrites().isEmpty)
        #expect(await client.lastRejectedWrites.isEmpty)
    }
}
