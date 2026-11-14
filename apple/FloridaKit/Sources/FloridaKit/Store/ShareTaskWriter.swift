import Foundation
import GRDB

public enum ShareTaskWriter {
    public enum CaptureError: Error, Hashable, Sendable, LocalizedError {
        case openFloridaOnce
        case invalidDraft

        public var errorDescription: String? {
            switch self {
            case .openFloridaOnce: "Open Florida once to prepare shared task capture."
            case .invalidDraft: "Enter a title and a positive duration with a valid source and repeat rule."
            }
        }
    }

    public static func save(
        _ draft: QuickAddDraft, captureID: UUID, categoryID: String = TaskCategory.inboxId,
        path: String? = nil, now: Date = Date()
    ) throws -> TaskItem {
        guard let path = path ?? AppDatabase.sharedURL()?.path else { throw CaptureError.openFloridaOnce }
        let store: AppDatabase
        do {
            store = try AppDatabase.openExisting(path: path, access: .readWrite, requireSync: false)
        } catch is AppDatabase.SharedStoreError {
            throw CaptureError.openFloridaOnce
        }
        defer { try? store.writer.close() }
        return try store.writer.write { db in
            let id = captureID.uuidString.lowercased()
            if let existing = try TaskItem.fetchOne(db, id: id) { return existing }
            guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (draft.durationMinutes ?? 30) > 0,
                  draft.recurrence?.validationMessage(asNewSeriesAt: now) == nil else { throw CaptureError.invalidDraft }
            if let source = draft.source, TaskSource.from(url: source.url, title: source.title) == nil {
                throw CaptureError.invalidDraft
            }
            var task = draft.applyingExplicitFields(to: TaskItem(
                id: id, categoryId: categoryID, title: draft.title, durationMinutes: 30,
                createdAt: now, updatedAt: now))
            try AppDatabase.sanitizeDestinations(of: &task, in: db)
            try AppDatabase.saveTask(task, in: db, now: now)
            guard let saved = try TaskItem.fetchOne(db, id: id) else { throw AppDatabase.WriteError.taskNoLongerExists }
            return saved
        }
    }
}
