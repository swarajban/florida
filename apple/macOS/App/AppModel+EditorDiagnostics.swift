#if DEBUG
import FloridaKit
import Foundation
import GRDB

struct EditorDiagnostics {
    var taskWrites = 0
    var queueChanges = 0
    var sounds = 0
    var pendingRows = 0
    var syncApplied = false

    var text: String {
        "taskWrites=\(taskWrites) queueChanges=\(queueChanges) sounds=\(sounds) pendingRows=\(pendingRows) syncApplied=\(syncApplied)"
    }
}

extension AppModel {
    func installEditorDiagnosticsIfNeeded() throws {
        guard UserDefaults.standard.bool(forKey: "demoData"),
              UserDefaults.standard.bool(forKey: "uiEditorDiagnostics"), let database
        else { return }
        try database.writer.write { db in
            try db.execute(sql: """
                CREATE TABLE editorDiagnosticsAudit (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    taskWrites INTEGER NOT NULL,
                    queueChanges INTEGER NOT NULL
                );
                INSERT INTO editorDiagnosticsAudit VALUES (1, 0, 0);
                CREATE TRIGGER editorDiagnosticsTaskUpdate AFTER UPDATE ON task
                BEGIN
                    UPDATE editorDiagnosticsAudit SET taskWrites = taskWrites + 1 WHERE id = 1;
                END;
                CREATE TRIGGER editorDiagnosticsQueueInsert AFTER INSERT ON pendingWrite
                BEGIN
                    UPDATE editorDiagnosticsAudit SET queueChanges = queueChanges + 1 WHERE id = 1;
                END;
                CREATE TRIGGER editorDiagnosticsQueueUpdate AFTER UPDATE ON pendingWrite
                BEGIN
                    UPDATE editorDiagnosticsAudit SET queueChanges = queueChanges + 1 WHERE id = 1;
                END;
                """)
        }
        editorDiagnostics = EditorDiagnostics()
        refreshEditorDiagnostics()
    }

    func refreshEditorDiagnostics() {
        guard var diagnostics = editorDiagnostics, let database else { return }
        do {
            let counts = try database.writer.read { db in
                let writes = try Row.fetchOne(db, sql: "SELECT taskWrites, queueChanges FROM editorDiagnosticsAudit WHERE id = 1")
                let taskWrites: Int = writes?["taskWrites"] ?? 0
                let queueChanges: Int = writes?["queueChanges"] ?? 0
                let pendingRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pendingWrite") ?? 0
                return (taskWrites, queueChanges, pendingRows)
            }
            diagnostics.taskWrites = counts.0
            diagnostics.queueChanges = counts.1
            diagnostics.pendingRows = counts.2
            editorDiagnostics = diagnostics
        } catch {
            statusMessage = "Could not read editor diagnostics: \(error.localizedDescription)"
        }
    }

    func applyEditorTestSyncIfNeeded() {
        let dateSync = UserDefaults.standard.bool(forKey: "uiTaskDateSyncDuringTyping")
        guard editorDiagnostics != nil, editorDiagnostics?.syncApplied == false,
              UserDefaults.standard.bool(forKey: "uiEditorSyncDuringTyping") || dateSync, let database
        else { return }
        do {
            guard var task = try database.task(id: dateSync ? "date-updated" : "demo-task-vpn") else { return }
            let now = Date()
            if dateSync {
                task.dueAt = ISO8601DateFormatter().date(from: "2026-11-18T07:59:59Z")
            } else {
                task.title = "Remote sync VPN title"
            }
            task.updatedAt = now
            var response = DemoData.syncResponse(now: now, calendar: calendar)
            response.cursor = ISO8601DateFormatter().string(from: now.addingTimeInterval(1))
            response.tasks = [task]
            if dateSync {
                response.placements = [Placement(
                    id: "date-placement", taskId: task.id,
                    startAt: ISO8601DateFormatter().date(from: "2026-11-17T20:00:00Z")!,
                    endAt: ISO8601DateFormatter().date(from: "2026-11-17T20:30:00Z")!,
                    pinned: false, computedAt: now)]
            } else {
                response.placements.append(Placement(
                    id: "editor-diagnostics-vpn-placement", taskId: task.id,
                    startAt: now.addingTimeInterval(900), endAt: now.addingTimeInterval(2700),
                    pinned: false, computedAt: now))
            }
            response.unscheduled.removeAll { $0.taskId == task.id }
            try database.apply(response)
            editorDiagnostics?.syncApplied = true
            refreshEditorDiagnostics()
        } catch {
            statusMessage = "Could not apply editor test sync: \(error.localizedDescription)"
        }
    }
}
#endif
