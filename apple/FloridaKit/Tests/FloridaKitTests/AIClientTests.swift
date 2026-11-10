import Foundation
import Testing
@testable import FloridaKit

@Suite struct AIClientTests {
    let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "secret-token")

    @Test func parseTaskSendsTextZoneAndNowAndDecodesTheDraft() async throws {
        let transport = FakeTransport([.ok(Data("""
            {"draft":{"title":"Send invoice","notes":"to Acme","durationMinutes":30,"minChunkMinutes":null,
              "priority":"high","deadlineType":"hard","dueAt":"2026-11-13T17:00:00-08:00","startAt":null,
              "pinnedStart":null,"categoryId":null,"rationale":"Due Friday 5pm."}}
            """.utf8))])
        let client = AIClient(config: config, transport: transport)

        let before = Date()
        let draft = try await client.parseTask("send acme invoice due fri", timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(draft == TaskDraft(
            title: "Send invoice", notes: "to Acme", durationMinutes: 30, priority: .high, deadlineType: .hard,
            dueAt: Fixtures.instant("2026-11-14T01:00:00Z"), rationale: "Due Friday 5pm."))

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/ai/parse-task")
        #expect(request.headers["Authorization"] == "Bearer secret-token")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try JSONCoding.decoder.decode(ParseTaskBody.self, from: try #require(request.body))
        #expect(body.text == "send acme invoice due fri")
        #expect(body.timeZone == "America/Los_Angeles")
        #expect(abs(body.now.timeIntervalSince(before)) < 60)
    }

    @Test func suggestCategoryDecodesASuggestionOrNone() async throws {
        let transport = FakeTransport([
            .ok(Data(#"{"categoryId":"work","rationale":"Mentions the quarterly report."}"#.utf8)),
            .ok(Data(#"{"categoryId":null,"rationale":"Nothing fits."}"#.utf8)),
        ])
        let client = AIClient(config: config, transport: transport)

        #expect(try await client.suggestCategory(title: "Q3 report", notes: "for Dana")
            == CategorySuggestion(categoryId: "work", rationale: "Mentions the quarterly report."))
        #expect(try await client.suggestCategory(title: "???", notes: nil) == CategorySuggestion(categoryId: nil, rationale: "Nothing fits."))

        let requests = transport.requests
        #expect(requests.map(\.path) == ["/api/ai/suggest-category", "/api/ai/suggest-category"])
        let first = try JSONCoding.decoder.decode(SuggestCategoryBody.self, from: try #require(requests[0].body))
        #expect(first.title == "Q3 report" && first.notes == "for Dana")
    }

    @Test func errorsAreTypedLikeSyncErrors() async throws {
        let transport = FakeTransport([
            .error(503, "ai is not configured (set ANTHROPIC_API_KEY)"),
            .error(401, "unauthorized"),
            .json(status: 200, body: Data(#"{"draft":{"title":"x"}}"#.utf8)),
        ])
        let client = AIClient(config: config, transport: transport)

        do {
            _ = try await client.parseTask("x")
            Issue.record("expected .http")
        } catch SyncError.http(let status, let body) {
            #expect(status == 503)
            #expect(body.contains("not configured"))
        }
        do {
            _ = try await client.suggestCategory(title: "x", notes: nil)
            Issue.record("expected .unauthorized")
        } catch SyncError.unauthorized {}
        do {
            _ = try await client.parseTask("x")
            Issue.record("expected .decoding")
        } catch SyncError.decoding {}
    }

    @Test func writeBriefAsksForAKindAndReturnsTheStoredBrief() async throws {
        let transport = FakeTransport([.ok(Data("""
            {"brief":{"id":"b1","kind":"weekly","date":"2026-11-08","headline":"A full week","body":"Gym moved to Wednesday.",
              "createdAt":"2026-11-08T18:00:00.000Z","updatedAt":"2026-11-08T18:00:00.000Z"}}
            """.utf8))])
        let brief = try await AIClient(config: config, transport: transport).writeBrief(.weekly)
        #expect(brief.kind == .weekly && brief.date == "2026-11-08" && brief.headline == "A full week")
        #expect(brief.updatedAt == Fixtures.instant("2026-11-08T18:00:00Z"))

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST" && request.path == "/api/ai/brief")
        let sent = try #require(request.body)
        #expect(try JSONSerialization.jsonObject(with: sent) as? [String: String] == ["kind": "weekly"])
    }

    @Test func explainPlacementSendsTheTaskAndReturnsTheWords() async throws {
        let transport = FakeTransport([
            .ok(Data(#"{"explanation":"Thursday is the first office day with 90 free minutes."}"#.utf8)),
            .error(404, "task gone not found"),
        ])
        let client = AIClient(config: config, transport: transport)
        #expect(try await client.explainPlacement(taskId: "t1") == "Thursday is the first office day with 90 free minutes.")
        let request = try #require(transport.requests.first)
        #expect(request.method == "POST" && request.path == "/api/ai/explain")
        let sent = try #require(request.body)
        #expect(try JSONSerialization.jsonObject(with: sent) as? [String: String] == ["taskId": "t1"])

        do {
            _ = try await client.explainPlacement(taskId: "gone")
            Issue.record("expected .http")
        } catch SyncError.http(let status, _) {
            #expect(status == 404)
        }
    }
}
