import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct ShareTaskWriterTests {
    private func file() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("florida.sqlite").path
    }

    private func remove(_ file: String) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: file).deletingLastPathComponent())
    }

    private func draft(_ title: String = "Shared task") -> QuickAddDraft {
        QuickAddDraft(title: title, source: TaskSource.from(url: "https://example.com/article"))
    }

    @Test func writesWhileHostRemainsOpenWithoutASyncOrToken() throws {
        let path = try file()
        defer { remove(path) }
        let host = try AppDatabase(path: path)
        let id = UUID()
        let saved = try ShareTaskWriter.save(draft(), captureID: id, path: path, now: Fixtures.t0)
        #expect(saved.id == id.uuidString.lowercased())
        #expect(saved.categoryId == TaskCategory.inboxId)
        #expect(saved.needsTriage)
        #expect(saved.durationMinutes == 30)
        #expect(saved.priority == .medium)
        #expect(saved.context == .computer)
        #expect(saved.deadlineType == .none)
        #expect(try host.task(id: saved.id) == saved)
        #expect(try host.cursor() == nil)
        let pending = try #require(try host.pendingWrites().first)
        #expect(pending.entityId == saved.id && pending.op == .put)
        let body = try JSONCoding.decoder.decode(TaskWrite.self, from: #require(pending.body))
        #expect(body == TaskWrite(saved))
    }

    @Test func refusesMissingOldAndFutureSchemasWithoutWritingOrMigrating() throws {
        let path = try file()
        defer { remove(path) }
        #expect(throws: ShareTaskWriter.CaptureError.openFloridaOnce) {
            try ShareTaskWriter.save(draft(), captureID: UUID(), path: path)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        let queue = try DatabaseQueue(path: path)
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        #expect(throws: ShareTaskWriter.CaptureError.openFloridaOnce) {
            try ShareTaskWriter.save(draft(), captureID: UUID(), path: path)
        }
        #expect(try queue.read { try AppDatabase.migrator.appliedIdentifiers($0) } == ["v1"])
        #expect(try queue.read { try TaskItem.fetchCount($0) } == 0)
        #expect(try queue.read { try PendingWrite.fetchCount($0) } == 0)
        try AppDatabase.migrator.migrate(queue)
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('future')") }
        #expect(throws: ShareTaskWriter.CaptureError.openFloridaOnce) {
            try ShareTaskWriter.save(draft(), captureID: UUID(), path: path)
        }
        #expect(try queue.read { try TaskItem.fetchCount($0) } == 0)
        #expect(try queue.read { try AppDatabase.migrator.appliedIdentifiers($0).contains("future") })
    }

    @Test func waitsForHostTransactionAndRefusesAnUnfinishedMigration() async throws {
        let path = try file()
        defer { remove(path) }
        var config = Configuration()
        config.allowsUnsafeTransactions = true
        let queue = try DatabaseQueue(path: path, configuration: config)
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try await queue.writeWithoutTransaction { try $0.execute(sql: "BEGIN IMMEDIATE; CREATE TABLE unfinished (id TEXT)") }
        let release = AsyncThrowingStream<Void, Error> { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) {
                do {
                    try queue.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
        #expect(throws: ShareTaskWriter.CaptureError.openFloridaOnce) {
            try ShareTaskWriter.save(draft(), captureID: UUID(), path: path)
        }
        for try await _ in release { }
        #expect(try await queue.read { try !$0.tableExists("unfinished") })
        #expect(try await queue.read { try TaskItem.fetchCount($0) } == 0)
    }

    @Test func waitsForARealHostWriteThenCaptures() async throws {
        let path = try file()
        defer { remove(path) }
        let host = try AppDatabase(path: path)
        var config = AppDatabase.sharedConfiguration()
        config.allowsUnsafeTransactions = true
        let queue = try DatabaseQueue(path: path, configuration: config)
        try await queue.writeWithoutTransaction {
            try $0.execute(sql: "BEGIN IMMEDIATE")
            try AppDatabase.saveTask(Fixtures.task(id: "host"), in: $0, now: Fixtures.t0)
        }
        let release = AsyncThrowingStream<Void, Error> { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) {
                do {
                    try queue.writeWithoutTransaction { try $0.execute(sql: "COMMIT") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
        let saved = try ShareTaskWriter.save(draft(), captureID: UUID(), path: path)
        for try await _ in release { }
        #expect(try host.task(id: saved.id) != nil)
        #expect(try host.openTasks().count == 2)
        #expect(try host.pendingWrites().count == 2)
    }

    @Test func concurrentHostAndExtensionWritesKeepEveryPair() async throws {
        let path = try file()
        defer { remove(path) }
        let host = try AppDatabase(path: path)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        try host.saveTask(Fixtures.task(id: "host-\(index)"), original: nil)
                    } else {
                        _ = try ShareTaskWriter.save(draft("Share \(index)"), captureID: UUID(), path: path)
                    }
                }
            }
            try await group.waitForAll()
        }
        let tasks = try host.openTasks()
        let writes = try host.pendingWrites()
        #expect(tasks.count == 20)
        #expect(writes.count == 20)
        #expect(Set(tasks.map(\.id)) == Set(writes.map(\.entityId)))
    }

    @Test(arguments: ["task", "pendingWrite"])
    func failureInEitherInsertRollsBackBoth(_ table: String) throws {
        let path = try file()
        defer { remove(path) }
        let host = try AppDatabase(path: path)
        try host.writer.write {
            try $0.execute(sql: "CREATE TRIGGER failCapture BEFORE INSERT ON \(table) BEGIN SELECT RAISE(ABORT, 'injected'); END")
        }
        #expect(throws: DatabaseError.self) {
            try ShareTaskWriter.save(draft(), captureID: UUID(), path: path)
        }
        #expect(try host.openTasks().isEmpty)
        #expect(try host.pendingWrites().isEmpty)
    }

    @Test func hostObservationReceivesTheCommittedTaskAndOutboxWithoutManualRefresh() async throws {
        let path = try file()
        defer { remove(path) }
        let host = try AppDatabase(path: path)
        let state = ObservedCounts()
        let token = ValueObservation.tracking { db in
            try [TaskItem.fetchCount(db), PendingWrite.fetchCount(db)]
        }.start(in: host.writer, scheduling: .async(onQueue: .global()), onError: { state.fail($0) }, onChange: { state.set($0) })
        defer { token.cancel() }
        try await state.wait(for: [0, 0])
        _ = try ShareTaskWriter.save(draft(), captureID: UUID(), path: path)
        try await state.wait(for: [1, 1])
    }

    @Test func concurrentDoubleSubmitIsIdempotentButANewShareCreatesAnotherTask() async throws {
        let path = try file()
        defer { remove(path) }
        let host = try AppDatabase(path: path)
        let id = UUID()
        try await withThrowingTaskGroup(of: TaskItem.self) { group in
            for _ in 0..<2 { group.addTask { try ShareTaskWriter.save(draft(), captureID: id, path: path) } }
            for try await task in group { #expect(task.id == id.uuidString.lowercased()) }
        }
        #expect(try host.openTasks().count == 1)
        #expect(try host.pendingWrites().count == 1)
        let write = try #require(try host.pendingWrites().first)
        let again = try ShareTaskWriter.save(draft("Different retry text"), captureID: id, path: path)
        #expect(again.title == "Shared task")
        #expect(try host.pendingWrites().first?.seq == write.seq)
        try host.deleteTask(id: again.id)
        #expect(try ShareTaskWriter.save(draft(), captureID: id, path: path).deletedAt != nil)
        _ = try ShareTaskWriter.save(draft(), captureID: UUID(), path: path)
        #expect(try host.openTasks().count == 1)
        #expect(try host.pendingWrites().count == 2)
    }

    @Test func settingsZoneDatesAndSomedayUseTheHostWriteRules() throws {
        let path = try file()
        defer { remove(path) }
        let host = try AppDatabase(path: path)
        try host.apply(SyncResponse(cursor: "c", settings: UserSettings(
            id: "default", timeZone: "America/Los_Angeles", updatedAt: Fixtures.t0), categories: [Fixtures.category(id: "work")]))
        let settings = try #require(try host.userSettings())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: settings.timeZone))
        let parsed = try #require(ShareDraftParser.parse(ShareInput(text: "Read ^nov 17 2026"), now: Fixtures.t0, calendar: calendar))
        let dated = try ShareTaskWriter.save(parsed, captureID: UUID(), categoryID: "work", path: path)
        #expect(dated.dueAt == JSONCoding.parseInstant("2026-11-18T01:00:00Z"))
        #expect(!dated.needsTriage)
        let undated = try ShareTaskWriter.save(draft(), captureID: UUID(), categoryID: "work", path: path)
        #expect(undated.needsTriage && !undated.someday)
        var someday = parsed
        someday.someday = true
        someday.pinnedStart = Fixtures.t0
        let saved = try ShareTaskWriter.save(someday, captureID: UUID(), categoryID: "work", path: path)
        #expect(saved.someday && !saved.needsTriage)
        #expect(saved.dueAt == nil && saved.pinnedStart == nil && saved.deadlineType == .none)
        #expect(try host.placements(in: Fixtures.allTime).isEmpty)
        let fallback = try ShareTaskWriter.save(parsed, captureID: UUID(), categoryID: "deleted-category", path: path)
        #expect(fallback.categoryId == TaskCategory.inboxId && fallback.needsTriage)
        for write in try host.pendingWrites() {
            let task = try #require(try host.task(id: write.entityId))
            #expect(try JSONCoding.decoder.decode(TaskWrite.self, from: #require(write.body)) == TaskWrite(task))
        }
    }

    @Test(arguments: [QuickAddDraft(), QuickAddDraft(title: "Bad", durationMinutes: 0), QuickAddDraft(
        title: "Bad source", source: TaskSource(url: "file:///private", title: "File", kind: .web))])
    func rejectsInvalidDraftsWithoutAQueueEntry(_ invalid: QuickAddDraft) throws {
        let path = try file()
        defer { remove(path) }
        let host = try AppDatabase(path: path)
        #expect(throws: ShareTaskWriter.CaptureError.invalidDraft) {
            try ShareTaskWriter.save(invalid, captureID: UUID(), path: path)
        }
        #expect(try host.openTasks().isEmpty)
        #expect(try host.pendingWrites().isEmpty)
    }

    @Test func expiredNewRecurrenceCannotCreateAnUnpushableTask() throws {
        let path = try file()
        defer { remove(path) }
        let host = try AppDatabase(path: path)
        let expired = QuickAddDraft(title: "Expired series", recurrence: TaskRecurrence(
            frequency: .day, interval: 1, timeZone: "UTC", startDate: "2026-01-01", endDate: "2026-01-02"))
        #expect(expired.recurrence?.validationMessage == nil)
        #expect(throws: ShareTaskWriter.CaptureError.invalidDraft) {
            try ShareTaskWriter.save(expired, captureID: UUID(), path: path, now: Fixtures.t0)
        }
        #expect(try host.openTasks().isEmpty)
        #expect(try host.pendingWrites().isEmpty)
    }
}

private final class ObservedCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int]?
    private var error: (any Error)?

    func set(_ value: [Int]) { lock.withLock { counts = value } }
    func fail(_ value: any Error) { lock.withLock { error = value } }

    func wait(for expected: [Int]) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while clock.now < deadline {
            let (value, failure) = lock.withLock { (counts, error) }
            if let failure { throw failure }
            if value == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(lock.withLock { counts } == expected)
    }
}
