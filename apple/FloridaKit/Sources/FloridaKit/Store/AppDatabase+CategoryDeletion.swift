import Foundation
import GRDB

extension AppDatabase {
    private struct CategoryDeletionRollback: Codable {
        var tasks: Set<String> = []
        var projects: Set<String> = []
        var taskWrites: Set<String> = []
        var projectWrites: Set<String> = []
    }

    private static let categoryRollbackPrefix = "category-delete-rollback:"

    func categoryDeletionsNeedingRecovery() throws -> [String] {
        try writer.read { db in
            let keys = try String.fetchAll(db, sql: "SELECT key FROM syncState WHERE key LIKE ?", arguments: [Self.categoryRollbackPrefix + "%"])
            guard !keys.isEmpty else { return [] }
            let pending = Set(try String.fetchAll(db, sql: "SELECT entityId FROM pendingWrite WHERE entity = 'category'"))
            return keys.map { String($0.dropFirst(Self.categoryRollbackPrefix.count)) }.filter { !pending.contains($0) }.sorted()
        }
    }

    private static func categoryDeletionRollback(_ db: Database, id: String) throws -> CategoryDeletionRollback? {
        guard let value = try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [categoryRollbackPrefix + id]) else { return nil }
        return try JSONCoding.decoder.decode(CategoryDeletionRollback.self, from: Data(value.utf8))
    }

    private static func storeCategoryDeletionRollback(_ db: Database, id: String, rollback: CategoryDeletionRollback) throws {
        let value = String(decoding: try JSONCoding.encoder.encode(rollback), as: UTF8.self)
        try db.execute(sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES (?, ?)", arguments: [categoryRollbackPrefix + id, value])
    }

    static func keepPendingCategoryReassignments(_ db: Database) throws {
        let ids = try String.fetchAll(db, sql: "SELECT entityId FROM pendingWrite WHERE entity = 'category' AND op = 'delete'")
        for id in ids { try reassignCategory(db, id: id) }
    }

    private static func reassignCategory(_ db: Database, id: String) throws {
        var rollback = try categoryDeletionRollback(db, id: id) ?? CategoryDeletionRollback()
        let tasks = Set(try String.fetchAll(db, sql: "SELECT id FROM task WHERE categoryId = ?", arguments: [id]))
        let projects = Set(try String.fetchAll(db, sql: "SELECT id FROM project WHERE categoryId = ?", arguments: [id]))
        let newTasks = tasks.subtracting(rollback.tasks)
        let newProjects = projects.subtracting(rollback.projects)
        rollback.tasks.formUnion(tasks)
        rollback.projects.formUnion(projects)
        rollback.taskWrites.formUnion(newTasks)
        rollback.projectWrites.formUnion(newProjects)
        for var write in try PendingWrite.filter(Column("entity") == "task" || Column("entity") == "project").fetchAll(db) {
            guard let body = write.body else { continue }
            var fields = try taskWriteObject(body)
            let isTask = write.entity == .task
            let newlyAffected = isTask ? newTasks : newProjects
            var eligible = isTask ? rollback.taskWrites : rollback.projectWrites
            if newlyAffected.contains(write.entityId), fields["categoryId"] as? String != id,
               !(write.op == .patch && fields["categoryId"] == nil) {
                eligible.remove(write.entityId)
            }
            if fields["categoryId"] as? String == id {
                eligible.insert(write.entityId)
                fields["categoryId"] = isTask ? TaskCategory.inboxId as Any : NSNull()
                write.body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
                try write.update(db)
            }
            if isTask { rollback.taskWrites = eligible } else { rollback.projectWrites = eligible }
        }
        try storeCategoryDeletionRollback(db, id: id, rollback: rollback)
        try db.execute(sql: "UPDATE task SET categoryId = ? WHERE categoryId = ?", arguments: [TaskCategory.inboxId, id])
        try db.execute(sql: "UPDATE project SET categoryId = NULL WHERE categoryId = ?", arguments: [id])
    }

    static func forgetCategoryReassignment(_ db: Database, entity: PendingWrite.Entity, id: String) throws {
        let keys = try String.fetchAll(db, sql: "SELECT key FROM syncState WHERE key LIKE ?", arguments: [categoryRollbackPrefix + "%"])
        for key in keys {
            let categoryId = String(key.dropFirst(categoryRollbackPrefix.count))
            guard var rollback = try categoryDeletionRollback(db, id: categoryId) else { continue }
            switch entity {
            case .task:
                rollback.tasks.remove(id)
                rollback.taskWrites.remove(id)
            case .project:
                rollback.projects.remove(id)
                rollback.projectWrites.remove(id)
            default:
                return
            }
            try storeCategoryDeletionRollback(db, id: categoryId, rollback: rollback)
        }
    }

    static func restoreCategoryReassignment(_ db: Database, id: String) throws {
        guard let rollback = try categoryDeletionRollback(db, id: id) else { return }
        for taskId in rollback.tasks {
            try db.execute(sql: "UPDATE task SET categoryId = ? WHERE id = ? AND categoryId = ?", arguments: [id, taskId, TaskCategory.inboxId])
        }
        for projectId in rollback.projects {
            try db.execute(sql: "UPDATE project SET categoryId = ? WHERE id = ? AND categoryId IS NULL", arguments: [id, projectId])
        }
        for var write in try PendingWrite.filter(Column("entity") == "task" || Column("entity") == "project").fetchAll(db) {
            let isTask = write.entity == .task
            guard (isTask ? rollback.taskWrites : rollback.projectWrites).contains(write.entityId), let body = write.body else { continue }
            var fields = try taskWriteObject(body)
            let reassigned = isTask ? fields["categoryId"] as? String == TaskCategory.inboxId
                : fields["categoryId"] is NSNull || (write.op == .put && fields["categoryId"] == nil)
            guard reassigned else { continue }
            fields["categoryId"] = id
            write.body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            try write.update(db)
        }
        try clearCategoryDeletionRollback(db, id: id)
    }

    static func finishCategoryDeletion(_ db: Database, id: String) throws {
        try reassignCategory(db, id: id)
        try clearCategoryDeletionRollback(db, id: id)
    }

    static func settleCategoryAction(_ db: Database, id: String, serverCopy: ServerCopy) throws {
        switch serverCopy {
        case .live:
            try restoreCategoryReassignment(db, id: id)
        case .missing, .tombstoned:
            try finishCategoryDeletion(db, id: id)
        case .unavailable:
            try db.execute(sql: "DELETE FROM syncState WHERE key = 'cursor'")
        }
        try keepPendingCategoryReassignments(db)
    }

    private static func clearCategoryDeletionRollback(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [categoryRollbackPrefix + id])
    }
}
