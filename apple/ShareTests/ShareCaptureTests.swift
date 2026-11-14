import FloridaKit
import Foundation
import Testing
@testable import FloridaShareLogic

@Suite @MainActor struct ShareCaptureTests {
    private func file() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        let store = try AppDatabase(path: path)
        try store.apply(SyncResponse(cursor: Date().ISO8601Format(), categories: [
            TaskCategory(id: "inbox", name: "Inbox", scheduleId: "work", createdAt: Date(), updatedAt: Date()),
            TaskCategory(id: "work", name: "Work", scheduleId: "work", createdAt: Date(), updatedAt: Date()),
        ]))
        try store.writer.close()
        return path
    }

    @Test(arguments: ["Fix crash #123", "Notes // draft", "Ship tomorrow !1"])
    func hostTitleIsLiteralUntilEdited(title: String) async throws {
        let path = try file()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = ShareCaptureModel(input: ShareInput(url: "https://example.com/a", pageTitle: title))
        await model.load(path: path)
        #expect(model.draft.title == title)
        #expect(model.draft.categoryHint == nil && model.draft.notes == nil && model.draft.dueAt == nil)
        #expect(model.goesToInbox && model.canAdd)
        model.edit(title + " ")
        #expect(!model.literalTitle)
        #expect(model.draft == ShareDraftParser.parse(ShareInput(url: "https://example.com/a", pageTitle: nil, text: title + " "), now: Date(), calendar: model.calendar).map { parsed in
            var draft = parsed
            draft.source = model.draft.source
            return draft
        })
    }

    @Test func editKeepsSourceNotesAndInboxRule() async throws {
        let path = try file()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = ShareCaptureModel(input: ShareInput(text: "Read https://example.com/a\nKeep this note"))
        await model.load(path: path)
        model.edit("Read #work ^someday\nKeep this note")
        #expect(model.draft.source?.url == "https://example.com/a")
        #expect(model.draft.notes == "Keep this note")
        #expect(model.category?.id == "work" && !model.goesToInbox)
        model.edit("Read #missing")
        #expect(!model.canAdd)
        model.selectedCategoryID = "work"
        #expect(model.canAdd && model.goesToInbox)
        model.edit("Read #inbox")
        #expect(model.selectedCategoryID == nil && model.category?.isInbox == true)
    }

    @Test func doubleSubmitAndCancelWriteAtMostOnce() async throws {
        let path = try file()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = ShareCaptureModel(input: ShareInput(text: "Read this"))
        await model.load(path: path)
        let write: @Sendable (QuickAddDraft, UUID, String) async throws -> TaskItem = { draft, id, category in
            try await Task.detached { try ShareTaskWriter.save(draft, captureID: id, categoryID: category, path: path) }.value
        }
        async let first = model.add(write: write)
        async let second = model.add(write: write)
        let saved = await [first, second].compactMap { $0 }
        #expect(saved.count == 1 && saved.first?.id == model.captureID.uuidString.lowercased())
        let store = try AppDatabase.openExisting(path: path, requireSync: false)
        defer { try? store.writer.close() }
        #expect(try store.pendingWrites().count == 1)
        let cancelled = ShareCaptureModel(input: ShareInput(text: "Cancel me"))
        await cancelled.load(path: path)
        #expect(cancelled.cancel())
        #expect(await cancelled.add(write: write) == nil)
        #expect(try store.pendingWrites().count == 1)
    }

    @Test func missingStoreShowsOpenOnceAndDoesNotCreateIt() async {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let model = ShareCaptureModel(input: ShareInput(text: "Read this"))
        await model.load(path: path)
        #expect(model.error == "Open Florida once to prepare shared task capture.")
        #expect(!model.canAdd && !FileManager.default.fileExists(atPath: path))
    }

    @Test func initializedUnsyncedStoreAndFailedWriteCanRetry() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AppDatabase(path: path)
        defer { try? store.writer.close() }
        let model = ShareCaptureModel(input: ShareInput(text: "Read this"))
        await model.load(path: path)
        #expect(model.canAdd && model.categories.isEmpty && model.goesToInbox)
        let id = model.captureID
        #expect(await model.add { _, _, _ in throw CocoaError(.fileWriteUnknown) } == nil)
        #expect(model.canAdd && model.error != nil)
        model.edit("Read this tomorrow")
        let saved = await model.add { draft, id, category in
            try await Task.detached { try ShareTaskWriter.save(draft, captureID: id, categoryID: category, path: path) }.value
        }
        #expect(saved?.id == id.uuidString.lowercased() && saved?.categoryId == "inbox")
        #expect(try store.pendingWrites().count == 1 && model.error == nil)
    }
}
