import Foundation
import GRDB
import Testing
@testable import FloridaKit
#if canImport(Darwin)
import Darwin
#endif

@Suite struct SharedStoreTests {
    @Test func iOSSharedFilesDeclareAfterFirstUnlockProtection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FloridaKit/Store/SharedStoreConfiguration.swift"), encoding: .utf8)
        #expect(source.contains("FileProtectionType.completeUntilFirstUserAuthentication"))
        #expect(source.contains(".protectionKey"))
    }

    #if os(iOS)
    @Test func sharedDatabaseAndSidecarsUseAfterFirstUnlockProtection() throws {
        let file = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        let host = try AppDatabase(path: file)
        try host.apply(SyncResponse(cursor: "ready"))
        for item in [URL(fileURLWithPath: file).deletingLastPathComponent().path, file, file + "-wal", file + "-shm"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: item)
            #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        }
        withExtendedLifetime(host) {}
    }
    #endif

    private func path() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("florida.sqlite").path
    }

    private func widgetOpen(_ path: String) throws -> AppDatabase {
        try AppDatabase.openExisting(path: path)
    }

    @Test func widgetOpenDoesNotCreateOrMigrate() throws {
        let missing = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: missing).deletingLastPathComponent().path) }
        #expect(throws: (any Error).self) { try widgetOpen(missing) }
        #expect(!FileManager.default.fileExists(atPath: missing))

        let old = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: old).deletingLastPathComponent().path) }
        let queue = try DatabaseQueue(path: old)
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        #expect(throws: (any Error).self) { try widgetOpen(old) }
        #expect(try queue.read { try AppDatabase.migrator.appliedMigrations($0) } == ["v1"])
    }

    @Test func widgetOpenIsReadOnlyAndUnavailableUntilFirstSync() throws {
        let file = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        let host = try AppDatabase(path: file)
        #expect(throws: (any Error).self) { try widgetOpen(file) }
        try host.apply(SyncResponse(cursor: "ready"))
        let widget = try widgetOpen(file)
        #expect(try widget.cursor() == "ready")
        #expect(throws: (any Error).self) { try widget.saveTask(Fixtures.task(id: "forbidden")) }
        #expect(try host.openTasks().isEmpty)
        #expect(try widget.writer.read { try Int.fetchOne($0, sql: "PRAGMA busy_timeout") } == 5_000)
    }

    @Test func appWriterWaitsForShortSecondWriterTransaction() async throws {
        let file = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        let host = try AppDatabase(path: file)
        var config = Configuration()
        config.allowsUnsafeTransactions = true
        let other = try DatabaseQueue(path: file, configuration: config)
        try await other.writeWithoutTransaction { try $0.execute(sql: "BEGIN IMMEDIATE") }
        let release = Task.detached {
            try await Task.sleep(for: .milliseconds(150))
            try await other.writeWithoutTransaction { try $0.execute(sql: "COMMIT") }
        }
        defer { release.cancel() }
        try host.saveTask(Fixtures.task(id: "after-lock"))
        try await release.value
        #expect(try host.task(id: "after-lock") != nil)
        #expect(try await host.writer.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA busy_timeout") } == 5_000)
    }

    @Test func secondWriterInvalidatesHostObservation() async throws {
        let file = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        let host = try AppDatabase(path: file)
        let other = try AppDatabase(path: file)
        await confirmation("host observes another connection's committed row") { received in
            let token = ValueObservation.tracking { try TaskItem.fetchCount($0) }
                .start(in: host.writer, scheduling: .async(onQueue: .global()), onError: { _ in }, onChange: { count in
                    if count == 1 { received() }
                })
            try? await Task.sleep(for: .milliseconds(100))
            try? other.saveTask(Fixtures.task(id: "external"))
            try? await Task.sleep(for: .milliseconds(400))
            withExtendedLifetime(token) {}
        }
    }

    @Test func walFilesSurviveClosingHostForReadOnlyExtension() throws {
        let file = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        func createAndClose() throws {
            let host = try AppDatabase(path: file)
            try host.apply(SyncResponse(cursor: "ready"))
            try host.writer.close()
        }
        try createAndClose()
        #expect(FileManager.default.fileExists(atPath: file + "-wal"))
        #expect(FileManager.default.fileExists(atPath: file + "-shm"))
        #expect(try widgetOpen(file).cursor() == "ready")
    }

    @Test func extensionWriterRefusesOldAndFutureSchemasWithoutMigrating() throws {
        let file = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        let queue = try DatabaseQueue(path: file)
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        #expect(throws: AppDatabase.SharedStoreError.self) {
            try AppDatabase.openExisting(path: file, access: .readWrite, requireSync: false)
        }
        #expect(try queue.read { try AppDatabase.migrator.appliedIdentifiers($0) } == ["v1"])
        try AppDatabase.migrator.migrate(queue)
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('future')") }
        #expect(throws: AppDatabase.SharedStoreError.self) {
            try AppDatabase.openExisting(path: file, access: .readWrite, requireSync: false)
        }
        #expect(throws: AppDatabase.SharedStoreError.self) {
            try AppDatabase.openExisting(path: file, access: .readOnly, requireSync: false)
        }
        #expect(try queue.read { try AppDatabase.migrator.appliedIdentifiers($0).contains("future") })
    }

    @Test func extensionAndAppWritesKeepRowsAndOutboxTogether() async throws {
        let file = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        let host = try AppDatabase(path: file)
        let other = try AppDatabase.openExisting(path: file, access: .readWrite, requireSync: false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let writer = index.isMultiple(of: 2) ? host : other
                    try writer.saveTask(Fixtures.task(id: "concurrent-\(index)"))
                }
            }
            try await group.waitForAll()
        }
        #expect(try host.openTasks().count == 20)
        #expect(try host.pendingWrites().count == 20)
    }

    @Test func extensionOpenDuringIncompleteMigrationRefusesTheOldSchema() async throws {
        let file = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        var configuration = Configuration()
        configuration.allowsUnsafeTransactions = true
        let migrating = try DatabaseQueue(path: file, configuration: configuration)
        try AppDatabase.migrator.migrate(migrating, upTo: "v1")
        try await migrating.writeWithoutTransaction {
            try $0.execute(sql: "BEGIN IMMEDIATE; CREATE TABLE unfinishedMigration (id TEXT)")
        }
        #expect(throws: AppDatabase.SharedStoreError.self) {
            try AppDatabase.openExisting(path: file, access: .readOnly, requireSync: false)
        }
        let release = Task.detached {
            try await Task.sleep(for: .milliseconds(150))
            try await migrating.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
        }
        #expect(throws: AppDatabase.SharedStoreError.self) {
            try AppDatabase.openExisting(path: file, access: .readWrite, requireSync: false)
        }
        try await release.value
        #expect(try await migrating.read { try AppDatabase.migrator.appliedIdentifiers($0) } == ["v1"])
        #expect(try await migrating.read { try !$0.tableExists("unfinishedMigration") })
    }

    @Test func explicitActiveRefreshRecoversUnsignaledExternalWrite() async throws {
        let file = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        let host = try AppDatabase(path: file)
        let external = try DatabaseQueue(path: file)
        await confirmation("active refresh observes an unsignaled writer") { received in
            let token = ValueObservation.tracking { try TaskItem.fetchCount($0) }
                .start(in: host.writer, scheduling: .async(onQueue: .global()), onError: { _ in }, onChange: { count in
                    if count == 1 { received() }
                })
            try? await Task.sleep(for: .milliseconds(100))
            try? await external.write { try Fixtures.task(id: "unsignaled").insert($0) }
            host.refreshExternalChanges()
            try? await Task.sleep(for: .milliseconds(400))
            withExtendedLifetime(token) {}
        }
    }

    @Test func onlyRealCommittedChangesBroadcast() async throws {
        let file = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        let host = try AppDatabase(path: file)
        let other = try AppDatabase.openExisting(path: file, access: .readWrite, requireSync: false)
        let counter = SignalCounter()
        let name = SharedStoreChanges.notificationName(for: file)
        #if canImport(Darwin)
        var token: Int32 = 0
        try #require(notify_register_dispatch(name, &token, .global(qos: .utility), { _ in counter.increment() }) == NOTIFY_STATUS_OK)
        defer { notify_cancel(token) }
        #else
        let token = NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(token) }
        #endif
        try other.saveTask(Fixtures.task(id: "committed"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.value == 1)

        enum Rollback: Error { case requested }
        func rollback() throws {
            try other.writer.write { db in
                try Fixtures.task(id: "rolled-back").insert(db)
                throw Rollback.requested
            }
        }
        #expect(throws: Rollback.self) { try rollback() }
        try await host.writer.write { try $0.notifyChanges(in: .fullDatabase) }
        host.refreshExternalChanges()
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.value == 1)
        #expect(try host.task(id: "rolled-back") == nil)
    }

    #if os(Linux)
    @Test func externalWriterProcessFixture() throws {
        guard let file = ProcessInfo.processInfo.environment["FLORIDA_TEST_SHARED_STORE"] else { return }
        let writer = try AppDatabase.openExisting(path: file, access: .readWrite, requireSync: false)
        try writer.saveTask(Fixtures.task(id: "separate-process"))
    }

    @Test func activeRefreshObservesAnActualSecondProcess() async throws {
        let file = try path()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        let host = try AppDatabase(path: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--filter", "externalWriterProcessFixture", "--testing-library", "swift-testing"]
        var environment = ProcessInfo.processInfo.environment
        environment["FLORIDA_TEST_SHARED_STORE"] = file
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try await confirmation("active refresh sees a different process without an in-process notification") { received in
            let token = ValueObservation.tracking { try TaskItem.fetchCount($0) }
                .start(in: host.writer, scheduling: .async(onQueue: .global()), onError: { _ in }, onChange: { count in
                    if count == 1 { received() }
                })
            try await Task.sleep(for: .milliseconds(100))
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(try host.task(id: "separate-process") != nil)
            #expect(try host.pendingWrites().map(\.entityId) == ["separate-process"])
            host.refreshExternalChanges()
            try await Task.sleep(for: .milliseconds(400))
            withExtendedLifetime(token) {}
        }
    }
    #endif
}

private final class SignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
