import Foundation
import GRDB

extension AppDatabase {
    @discardableResult
    public func updateTask(id: String, now: Date = Date(), _ update: (inout TaskItem) throws -> Bool) throws -> Bool {
        try writer.write { db in
            guard var live = try TaskItem.fetchOne(db, id: id), live.deletedAt == nil else {
                throw WriteError.taskNoLongerExists
            }
            guard try update(&live) else { return false }
            try Self.sanitizeDestinations(of: &live, in: db)
            try Self.saveTask(live, in: db, now: now)
            return true
        }
    }

    public func saveTask(_ draft: TaskItem, original: TaskItem?, now: Date = Date()) throws {
        try writer.write { db in
            guard let original else {
                var task = draft
                try Self.sanitizeDestinations(of: &task, in: db)
                try Self.saveTask(task, in: db, now: now)
                return
            }
            guard var live = try TaskItem.fetchOne(db, id: original.id), live.deletedAt == nil,
                  draft.id == original.id else { throw WriteError.taskNoLongerOpen }
            let reopening = original.completedAt != nil && draft.completedAt == nil
                && original.completedAt?.databaseValue == live.completedAt?.databaseValue
            guard live.isOpen || reopening else { throw WriteError.taskNoLongerOpen }
            func apply<Value: Equatable>(_ path: WritableKeyPath<TaskItem, Value>) {
                if draft[keyPath: path] != original[keyPath: path] {
                    live[keyPath: path] = draft[keyPath: path]
                }
            }
            func applyDate(_ path: WritableKeyPath<TaskItem, Date?>) {
                if draft[keyPath: path]?.databaseValue != original[keyPath: path]?.databaseValue {
                    live[keyPath: path] = draft[keyPath: path]
                }
            }
            apply(\.categoryId)
            apply(\.title)
            apply(\.notes)
            apply(\.source)
            apply(\.durationMinutes)
            apply(\.minChunkMinutes)
            apply(\.priority)
            apply(\.deadlineType)
            applyDate(\.dueAt)
            applyDate(\.startAt)
            apply(\.scheduleId)
            apply(\.context)
            apply(\.projectId)
            apply(\.attention)
            applyDate(\.pinnedStart)
            apply(\.completedMinutes)
            applyDate(\.completedAt)
            apply(\.recurrence)
            try Self.sanitizeDestinations(of: &live, in: db)
            if draft.durationMinutes != original.durationMinutes,
               live.completedMinutes >= live.durationMinutes, live.completedAt == nil {
                live.completedAt = now
            }
            try Self.saveTask(live, in: db, now: now)
        }
    }

    public func saveEvent(_ draft: CalendarEvent, original: CalendarEvent?, recurrence: EventRecurrence? = nil, now: Date = Date()) throws {
        try writer.write { db in
            guard let original else {
                try Self.saveEvent(draft, recurrence: recurrence, in: db, now: now)
                return
            }
            guard var live = try CalendarEvent.fetchOne(db, id: original.id), live.deletedAt == nil,
                  live.status != "cancelled", draft.id == original.id else { throw WriteError.eventNoLongerExists }
            let before = live
            func apply<Value: Equatable>(_ path: WritableKeyPath<CalendarEvent, Value>) {
                if draft[keyPath: path] != original[keyPath: path] {
                    live[keyPath: path] = draft[keyPath: path]
                }
            }
            func applyDate(_ path: WritableKeyPath<CalendarEvent, Date?>) {
                if draft[keyPath: path]?.databaseValue != original[keyPath: path]?.databaseValue {
                    live[keyPath: path] = draft[keyPath: path]
                }
            }
            apply(\.calendarId)
            apply(\.summary)
            apply(\.location)
            apply(\.description)
            applyDate(\.startAt)
            applyDate(\.endAt)
            apply(\.allDay)
            apply(\.responseStatus)
            guard live != before else { return }
            try Self.saveEvent(live, recurrence: recurrence, in: db, now: now)
        }
    }

    public func saveProject(_ draft: Project, original: Project?, now: Date = Date()) throws {
        try writer.write { db in
            guard let original else {
                var project = draft
                if let categoryId = project.categoryId {
                    let category = try TaskCategory.fetchOne(db, id: categoryId)
                    if category == nil || category?.deletedAt != nil { project.categoryId = nil }
                }
                try Self.saveProject(project, in: db, now: now)
                return
            }
            guard var live = try Project.fetchOne(db, id: original.id), live.deletedAt == nil,
                  draft.id == original.id else { throw WriteError.projectNoLongerExists }
            let before = live
            func apply<Value: Equatable>(_ path: WritableKeyPath<Project, Value>) {
                if draft[keyPath: path] != original[keyPath: path] {
                    live[keyPath: path] = draft[keyPath: path]
                }
            }
            apply(\.name)
            apply(\.status)
            apply(\.categoryId)
            apply(\.notes)
            apply(\.nextStep)
            apply(\.parallel)
            apply(\.weeklyMinutes)
            apply(\.sortOrder)
            if let categoryId = live.categoryId {
                let category = try TaskCategory.fetchOne(db, id: categoryId)
                if category == nil || category?.deletedAt != nil { live.categoryId = nil }
            }
            guard live != before else { return }
            try Self.saveProject(live, in: db, now: now)
        }
    }

    @discardableResult
    public func restoreTask(_ snapshot: TaskItem, now: Date = Date()) throws -> Bool {
        try writer.write { db in
            if let live = try TaskItem.fetchOne(db, id: snapshot.id), live.deletedAt == nil {
                throw WriteError.taskAlreadyRestored
            }
            var restored = snapshot
            restored.deletedAt = nil
            let stoppedSeries = restored.recurrence != nil || restored.recurrenceSeriesId != nil
            restored.recurrence = nil
            restored.recurrenceSeriesId = nil
            restored.recurrenceDate = nil
            try Self.sanitizeDestinations(of: &restored, in: db)
            try Self.saveTask(restored, in: db, now: now)
            try db.execute(sql: "UPDATE task SET recurrenceSeriesId = NULL, recurrenceDate = NULL WHERE id = ?", arguments: [restored.id])
            return stoppedSeries
        }
    }

    private static func sanitizeDestinations(of task: inout TaskItem, in db: Database) throws {
        let category = try TaskCategory.fetchOne(db, id: task.categoryId)
        if category == nil || category?.deletedAt != nil {
            task.categoryId = TaskCategory.inboxId
        }
        if let projectId = task.projectId {
            let project = try Project.fetchOne(db, id: projectId)
            if project == nil || project?.deletedAt != nil {
                task.projectId = nil
            }
        }
    }
}
