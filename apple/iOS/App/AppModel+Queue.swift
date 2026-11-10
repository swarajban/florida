import FloridaKit
import Foundation

// The sync queue as Settings shows it: local writes still waiting to be pushed (retry pushes now,
// discard drops one), and writes the server refused (4xx), kept until dismissed because the next
// push resets `SyncClient.lastRejectedWrites`.

extension AppModel {
    /// Something `SyncErrorBanner` would show: a store or sync error, or refused changes.
    var hasProblem: Bool {
        storeError != nil || lastError != nil || !rejectedChanges.isEmpty
    }

    /// Re-reads the queue; called whenever the observed pending-write count changes.
    func refreshPendingWrites() {
        pendingWrites = (try? database?.pendingWrites()) ?? []
    }

    /// Adds the client's rejections from the last push to `rejectedChanges`.
    func recordRejections(_ rejected: [RejectedWrite]) {
        let now = Date()
        for rejection in rejected {
            let write = rejection.write
            rejectedChanges.removeAll { $0.entity == write.entity && $0.entityId == write.entityId }
            rejectedChanges.append(RejectedChange(
                id: "\(write.entity.rawValue)-\(write.entityId)-\(now.timeIntervalSince1970)",
                entity: write.entity, entityId: write.entityId, op: write.op,
                status: rejection.status, message: rejection.message, at: now, body: write.body))
        }
    }

    /// Drops a queued write and puts the server's copy of its row back (removing the row when the
    /// server has it tombstoned, keeping it when the server never had it). One round trip, shown
    /// through `isSyncing`. The write leaves the queue before the server is asked, so when that
    /// fails the toast says the row was not reset; a local store failure keeps the write queued.
    func discardPendingWrite(_ write: PendingWrite) {
        guard let syncClient else {
            showToast(Toast(message: "Connect to the server in Settings first.", systemImage: "exclamationmark.triangle.fill", style: .error))
            return
        }
        Task { [weak self] in
            self?.activeOperations += 1
            defer { self?.activeOperations -= 1 }
            do {
                try await syncClient.discard(write)
            } catch let error as SyncError {
                self?.showToast(Toast(
                    message: "Discarded, but could not reset to the server's copy: \(Self.describe(error))",
                    systemImage: "exclamationmark.triangle.fill", style: .error))
            } catch {
                self?.showToast(Toast(message: "Could not discard: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill", style: .error))
            }
        }
    }

    /// Retries the original task intent, never a full snapshot of the reconciled row. Other
    /// entities retain their existing retry behavior.
    func retry(_ change: RejectedChange) {
        let ok = write { database in
            switch (change.entity, change.op) {
            case (.task, .put), (.task, .patch):
                try database.requeue(PendingWrite(
                    entity: .task, entityId: change.entityId, op: change.op, body: change.body, createdAt: change.at))
            case (.task, .delete):
                try database.deleteTask(id: change.entityId)
            case (.category, .put), (.category, .patch):
                guard let category = self.category(id: change.entityId) else { throw LocalWriteError("The category is gone.") }
                try database.saveCategory(category)
            case (.category, .delete):
                try database.deleteCategory(id: change.entityId)
            case (.schedule, .put), (.schedule, .patch):
                guard let schedule = self.schedule(id: change.entityId) else { throw LocalWriteError("The schedule is gone.") }
                try database.saveSchedule(schedule)
            case (.schedule, .delete):
                try database.deleteSchedule(id: change.entityId)
            case (.event, .put), (.event, .patch):
                guard let event = try database.event(id: change.entityId) else { throw LocalWriteError("The event is gone.") }
                try database.saveEvent(event)
            case (.event, .delete):
                try database.deleteEvent(id: change.entityId)
            case (.project, .put), (.project, .patch):
                guard let project = try database.project(id: change.entityId), project.deletedAt == nil else {
                    throw LocalWriteError("The project is gone.")
                }
                try database.saveProject(project)
            case (.project, .delete):
                try database.deleteProject(id: change.entityId)
            case (.dayOverride, .put), (.dayOverride, .patch):
                // The entity id is the date; the store kept the kind the user chose.
                guard let day = try database.dayOverrides().first(where: { $0.date == change.entityId }) else {
                    throw LocalWriteError("That day is back on its usual routine.")
                }
                try database.setDay(day.date, kind: day.kind, note: day.note)
            case (.dayOverride, .delete):
                try database.clearDay(change.entityId)
            }
        }
        if ok {
            dismissRejection(change)
        }
    }

    func dismissRejection(_ change: RejectedChange) {
        rejectedChanges.removeAll { $0.id == change.id }
    }

    /// "Task “Pay taxes”", "Category “Work”", or the kind and id when the row is gone.
    func describeEntity(_ entity: PendingWrite.Entity, id: String) -> String {
        switch entity {
        case .task:
            let title = task(id: id)?.title ?? (try? database?.task(id: id))?.title
            return title.map { "Task “\($0)”" } ?? "Task \(id.prefix(8))"
        case .category:
            return category(id: id).map { "Category “\($0.name)”" } ?? "Category \(id.prefix(8))"
        case .schedule:
            return schedule(id: id).map { "Schedule “\($0.name)”" } ?? "Schedule \(id.prefix(8))"
        case .event:
            let summary = (try? database?.event(id: id))?.summary
            return summary.map { "Event “\($0)”" } ?? "Event \(id.prefix(8))"
        case .project:
            let name = project(id: id)?.name ?? (try? database?.project(id: id))?.name
            return name.map { "Project “\($0)”" } ?? "Project \(id.prefix(8))"
        case .dayOverride:
            // The id is the date, "YYYY-MM-DD".
            return "Day \(id)"
        }
    }
}
