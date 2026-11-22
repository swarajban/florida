import Foundation
import Testing
@testable import FloridaKit

@Suite struct QuickAddTraceTests {
    @Test func traceIsOptInBoundedAndRedactsInput() throws {
        let trace = QuickAddTrace()
        let phrase = "fixture-private-phrase"
        let selection = NSRange(location: 0, length: 0)
        trace.input("disabled", buffer: phrase, selection: selection, marked: false)
        #expect(trace.report() == nil)

        trace.start()
        for _ in 0..<135 {
            trace.input("edit", buffer: phrase, selection: selection, marked: true,
                        replacement: "fixture-private-replacement", range: NSRange(location: 0, length: 4))
        }
        trace.submit(from: "toolbar.plus", mirror: phrase, title: phrase)
        let report = try #require(trace.report())
        #expect(report.split(separator: "\n").count == 129)
        #expect(report.contains("dropped=8"))
        #expect(report.contains("selection=0:0 marked=true range=0:4 replacement[tag="))
        #expect(!report.contains("fixture-private"))
        let submit = try #require(report.split(separator: "\n").last)
        let matches = submit.matches(of: /tag=([a-f0-9]+)/)
        #expect(matches.count == 2)
        #expect(matches.first?.1 == matches.last?.1)
        trace.start()
        #expect(trace.report() == nil)
    }

    @Test func syncTracesOnlyTheTrackedTasksActualWireTitles() async throws {
        let db = try AppDatabase.inMemory()
        let trace = QuickAddTrace()
        let taskID = "117a93b2-d2d8-46ee-ae4d-62e4ec919e06"
        var task = Fixtures.task(id: taskID, title: "Synthetic fixture title")
        task.notes = "fixture-private-notes"
        let unrelated = Fixtures.task(id: "unrelated", title: "fixture-private-unrelated")
        try db.saveTask(unrelated, now: Fixtures.t0)
        trace.start()
        trace.preview(task.title)
        trace.submit(from: "toolbar.plus", mirror: task.title, title: task.title)
        trace.track(taskID: taskID, title: task.title)
        #expect(!trace.isCapturingInput)
        try db.saveTask(task, now: Fixtures.t0.addingTimeInterval(1))
        var accepted = task
        accepted.title = "fixture title"
        let transport = FakeTransport([
            .ok(try Fixtures.putResponse("task", unrelated)),
            .ok(try Fixtures.putResponse("task", accepted)),
            .ok(try Fixtures.putResponse("task", accepted)),
        ])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "fixture-private-token")
        let client = SyncClient(database: db, config: config, transport: transport, quickAddTrace: trace)
        #expect(try await client.push() == 2)
        accepted.notes = "fixture-private-edited-notes"
        try db.saveTask(accepted, now: Fixtures.t0.addingTimeInterval(2))
        #expect(try await client.push() == 1)

        let report = try #require(trace.report())
        let lines = report.split(separator: "\n")
        try #require(lines.count == 8)
        #expect(lines[0].contains(taskID))
        #expect(lines[1].hasPrefix("preview tag="))
        #expect(lines[2].hasPrefix("submit toolbar.plus"))
        #expect(lines[4].hasPrefix("send put tag="))
        #expect(lines[4].hasSuffix("words=3 first=9"))
        #expect(lines[5].hasSuffix("words=2 first=7"))
        #expect(lines[6] == "send patch no title")
        #expect(!report.contains("fixture"))
        let tags = report.matches(of: /tag=([a-f0-9]+)/).map { $0.1 }
        try #require(tags.count == 7)
        #expect(Set(tags.prefix(5)).count == 1)
        #expect(tags[4] != tags[5] && tags[5] == tags[6])
    }

    @Test func failedLocalSaveDoesNotConsumeTheTrace() {
        let trace = QuickAddTrace()
        trace.start()
        trace.track(taskID: "first", title: "Private")
        trace.localSaveFailed(taskID: "different")
        #expect(!trace.isCapturingInput)
        trace.localSaveFailed(taskID: "first")
        #expect(trace.isCapturingInput)
        #expect(trace.report()?.contains("local save failed") == true)
    }
}
