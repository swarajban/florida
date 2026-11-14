import FloridaKit
import Foundation
import Observation

@Observable @MainActor
final class ShareCaptureModel {
    let captureID = UUID()
    private(set) var text: String
    private(set) var draft: QuickAddDraft
    private(set) var categories: [TaskCategory] = []
    private(set) var calendar = Calendar(identifier: .gregorian)
    private(set) var ready = false
    private(set) var submitted = false
    private(set) var saving = false
    private(set) var finished = false
    private(set) var error: String?
    private(set) var literalTitle: Bool
    var selectedCategoryID: String?
    private let source: TaskSource?
    private let now: Date

    init(input: ShareInput, now: Date = Date()) {
        self.now = now
        let parsed = ShareDraftParser.parse(input, now: now, calendar: .current) ?? QuickAddDraft()
        source = parsed.source
        let text = input.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? input.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? parsed.title
        let literalTitle = input.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || input.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        self.text = text
        self.literalTitle = literalTitle
        draft = literalTitle ? QuickAddDraft(title: String(text.prefix(120)), source: parsed.source) : parsed
        if literalTitle, text.count > 120 { draft.notes = text }
    }

    var category: TaskCategory? {
        if let selectedCategoryID { return categories.first { $0.id == selectedCategoryID } }
        if let hint = draft.categoryHint { return QuickAddTaskBuilder.matchCategory(hint: hint, in: categories) }
        return categories.first(where: \.isInbox)
    }

    var goesToInbox: Bool {
        categoryID == TaskCategory.inboxId || (draft.dueAt == nil && draft.startAt == nil && draft.pinnedStart == nil && !draft.someday)
    }

    var categoryID: String? {
        if selectedCategoryID != nil || draft.categoryHint != nil { return category?.id }
        return TaskCategory.inboxId
    }

    var canAdd: Bool { ready && !submitted && !finished && categoryID != nil && !draft.title.isEmpty }

    func load(path: String? = nil) async {
        do {
            let metadata = try await Task.detached {
                guard let path = path ?? AppDatabase.sharedURL()?.path else { throw ShareTaskWriter.CaptureError.openFloridaOnce }
                let store = try AppDatabase.openExisting(path: path, requireSync: false)
                defer { try? store.writer.close() }
                return (try store.categories(), try store.userSettings()?.timeZone)
            }.value
            categories = metadata.0
            calendar.timeZone = metadata.1.flatMap(TimeZone.init(identifier:)) ?? .current
            if !literalTitle { reparse() }
            ready = true
        } catch {
            self.error = "Open Florida once to prepare shared task capture."
        }
    }

    func edit(_ value: String) {
        guard !submitted && !finished else { return }
        text = value
        literalTitle = false
        reparse()
    }

    private func reparse() {
        let hint = draft.categoryHint
        draft = ShareDraftParser.parse(ShareInput(url: source?.url, text: text), now: now, calendar: calendar) ?? QuickAddDraft()
        draft.source = source ?? draft.source
        if draft.categoryHint != hint { selectedCategoryID = nil }
    }

    func cancel() -> Bool {
        guard !saving && !finished else { return false }
        finished = true
        return true
    }

    func add(
        write: @escaping @Sendable (QuickAddDraft, UUID, String) async throws -> TaskItem
    ) async -> TaskItem? {
        guard canAdd, let categoryID else { return nil }
        submitted = true
        saving = true
        error = nil
        defer { saving = false }
        do {
            let saved = try await write(draft, captureID, categoryID)
            finished = true
            return saved
        } catch {
            submitted = false
            if error as? ShareTaskWriter.CaptureError == .openFloridaOnce { ready = false }
            self.error = error is ShareTaskWriter.CaptureError
                ? (error as? LocalizedError)?.errorDescription
                : "Couldn’t save this task. Try Add again."
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
