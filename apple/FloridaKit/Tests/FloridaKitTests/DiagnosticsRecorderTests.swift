import Foundation
import Testing
@testable import FloridaKit

@Suite struct DiagnosticsRecorderTests {
    private var metadata: DiagnosticsRecorder.Metadata {
        .init(device: "fixture phone", serverURL: URL(string: "https://user:private-password@florida.test/api?token=private-query"),
            syncState: "idle", pending: 3, rejected: 2)
    }

    @Test func optInRingKeepsNewestEventsInOrderAndClearReleasesThem() throws {
        let recorder = DiagnosticsRecorder(capacity: 3, limit: .seconds(60), clock: { .now })
        func fields() -> [String: DiagnosticsRecorder.Field] {
            Issue.record("The recorder evaluated fields while off")
            return [:]
        }
        recorder.record("fixture", "disabled", fields())
        #expect(recorder.report(metadata) == nil)

        recorder.start()
        for n in 0..<8 { recorder.record("fixture", "event-\(n)") }
        recorder.stop()
        recorder.record("fixture", "stopped", fields())
        let report = try #require(recorder.report(metadata))
        let lines = report.split(separator: "\n")
        #expect(lines.count == 7)
        #expect(lines[3].contains("state=manual includeText=false limitSeconds=60 capacity=3 events=3 dropped=5"))
        #expect(lines.suffix(3).map { $0.split(separator: " ").last } == ["fixture.event-5", "fixture.event-6", "fixture.event-7"])
        recorder.clear()
        #expect(recorder.status == nil)
        #expect(recorder.report(metadata) == nil)
    }

    @Test func expiresExactlyAtTheMonotonicDeadline() throws {
        let epoch = ContinuousClock.now
        let clock = TestDiagnosticsClock(epoch)
        let recorder = DiagnosticsRecorder(capacity: 5, limit: .seconds(2), clock: { clock.now })
        recorder.start()
        clock.advance(by: .seconds(1))
        recorder.record("test", "before")
        #expect(recorder.status?.isRecording == true)
        clock.advance(by: .seconds(1))
        recorder.record("test", "after")
        #expect(recorder.status?.isRecording == false)
        #expect(recorder.status?.count == 1)
        clock.advance(by: .seconds(2))
        recorder.stop()
        #expect(recorder.status?.elapsed == 2)
        #expect(try #require(recorder.report(metadata)).contains("state=time-limit"))
    }

    @Test func reportEscapesUserTextAndNeverIncludesKnownCredentials() throws {
        let recorder = DiagnosticsRecorder()
        let phrase = "fixture-private phrase\nanother line"
        recorder.start()
        recorder.input("edit", buffer: phrase, selection: NSRange(location: 0, length: 0), marked: true,
                       replacement: "fixture-private replacement", range: NSRange(location: 0, length: 4))
        recorder.record("quick-add", "submit", ["mirror": .text(phrase), "parsed": .text(phrase)])
        let redacted = try #require(recorder.report(metadata))
        #expect(redacted.hasPrefix("Florida diagnostics v2\napp="))
        #expect(redacted.contains(#"device="fixture phone""#))
        #expect(redacted.contains(#"server="florida.test" sync="idle" pending=3 rejected=2"#))
        #expect(!redacted.contains("fixture-private"))
        #expect(redacted.contains(#"marked="true" range="0:4" replacement="tag="#))
        #expect(redacted.contains(#"selection="0:0""#))
        let tags = redacted.matches(of: /tag=([a-f0-9]+)/).map(\.1)
        try #require(tags.count == 4)
        #expect(tags[0] == tags[2] && tags[2] == tags[3] && tags[0] != tags[1])

        recorder.start(includeText: true, excludingToken: "private-secret")
        recorder.input("edit", buffer: "private-unsubmitted", selection: NSRange(location: 0, length: 0), marked: false)
        recorder.record("quick-add", "submit", ["title": .text(phrase)])
        for text in ["paste private-secret", "Authorization: Bearer private-header", "ya29.private-google",
                     "https://florida.test/?code=private-code", "aaaa.apps.googleusercontent.com"] {
            recorder.record("quick-add", "edit", ["buffer": .text(text)])
        }
        recorder.error("sync", "error", SyncError.http(status: 403, body: "private-error-body"))
        let included = try #require(recorder.report(metadata))
        #expect(included.contains(#"text=fixture-private phrase\nanother line"#))
        #expect(included.contains(#"sync.error error="http" status="403""#))
        #expect(included.components(separatedBy: "[credential omitted]").count == 6)
        for secret in ["private-secret", "private-header", "private-google", "private-code",
                       "private-password", "private-query", "private-error-body", "googleusercontent.com", "private-unsubmitted"] {
            #expect(!included.contains(secret))
        }
    }

    @Test func syncCapturesAllWritesAndComparesOnlyAllowlistedWireAndAcceptedTitles() async throws {
        let db = try AppDatabase.inMemory()
        let recorder = DiagnosticsRecorder()
        let taskID = "117a93b2-d2d8-46ee-ae4d-62e4ec919e06"
        var task = Fixtures.task(id: taskID, title: "Synthetic fixture title")
        task.notes = "fixture-private-notes"
        let unrelated = Fixtures.task(id: "unrelated", title: "fixture-private-unrelated")
        try db.saveTask(unrelated, now: Fixtures.t0)
        recorder.start()
        recorder.record("quick-add", "submit", ["mirror": .text(task.title), "parsed": .text(task.title)])
        try db.saveTask(task, now: Fixtures.t0.addingTimeInterval(1))
        var accepted = task
        accepted.title = "fixture title"
        let transport = FakeTransport([
            .ok(try Fixtures.putResponse("task", unrelated)),
            .ok(try Fixtures.putResponse("task", accepted)),
            .ok(try Fixtures.putResponse("task", accepted)),
            try .ok(SyncResponse(cursor: "2026-11-21T22:01:02.123Z", tasks: [accepted])),
        ])
        let config = ServerConfig(baseURL: URL(string: "https://florida.test")!, token: "fixture-private-token")
        let client = SyncClient(database: db, config: config, transport: transport, diagnostics: recorder)
        #expect(try await client.push() == 2)
        accepted.notes = "fixture-private-edited-notes"
        try db.saveTask(accepted, now: Fixtures.t0.addingTimeInterval(2))
        #expect(try await client.sync() == 1)

        let report = try #require(recorder.report(metadata))
        let lines = report.split(separator: "\n")
        let sends = lines.filter { $0.contains("http.write-send") }
        try #require(sends.count == 3)
        #expect(sends[0].contains(#"method="PUT""#))
        #expect(sends[1].contains(#"path="/api/tasks/:id""#))
        #expect(sends[1].contains("words=3 first=9"))
        #expect(sends[2].contains(#"method="PATCH""#))
        #expect(!sends[2].contains("title="))
        #expect(lines.filter { $0.contains("http.write-end") && $0.contains(#"status="200""#) && $0.contains(" ms=") }.count == 3)
        #expect(lines.contains { $0.contains(#"sync.pull-end"#) && $0.contains(#"cursor="2026-11-21T22:01:02.123Z""#) && $0.contains(#"tasks="1""#) })
        #expect(!report.contains("fixture-private") && !report.contains(taskID))
        let tags = report.matches(of: /tag=([a-f0-9]+)/).map(\.1)
        try #require(tags.count == 7)
        #expect(tags[0] == tags[1] && tags[0] == tags[4] && tags[4] != tags[5] && tags[5] == tags[6])
    }

    @Test func rejectedAndDeferredWritesRecordStatusWithoutErrorBodies() async throws {
        let db = try AppDatabase.inMemory()
        let recorder = DiagnosticsRecorder()
        let task = Fixtures.task(id: "task", title: "Example fixture-private-token")
        try db.saveTask(task, now: Fixtures.t0)
        let transport = FakeTransport([
            .error(503, "private-service-error"),
            .error(422, "private-validation-error"),
            .error(404, "missing"),
        ])
        let config = ServerConfig(baseURL: URL(string: "https://florida.test")!, token: "fixture-private-token")
        let client = SyncClient(database: db, config: config, transport: transport, diagnostics: recorder)
        recorder.start(includeText: true)
        await #expect(throws: SyncError.self) { try await client.push() }
        #expect(try await client.push() == 0)
        let report = try #require(recorder.report(metadata))
        #expect(report.contains("write.retry-pending"))
        #expect(report.contains(#"status="503""#))
        #expect(report.contains("write.rejected"))
        #expect(report.contains(#"status="422""#))
        #expect(report.contains("[credential omitted]") && !report.contains("fixture-private-token"))
        #expect(!report.contains("private-service-error") && !report.contains("private-validation-error"))
    }
}

private final class TestDiagnosticsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant

    init(_ instant: ContinuousClock.Instant) { self.instant = instant }
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(by duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}
