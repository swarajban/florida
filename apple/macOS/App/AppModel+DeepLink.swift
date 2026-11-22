import FloridaKit
import Foundation

extension AppModel {
    func openDeepLink(_ url: URL) {
        guard let link = DeepLink(url: url) else {
            DiagnosticsRecorder.shared.record("mac.deepLink", "unrecognized")
            return
        }
        transitionInteraction(to: .browsing)
        switch link {
        case .agenda:
            DiagnosticsRecorder.shared.record("mac.deepLink", "agenda")
            focus = .calendar
            if let date = link.agendaDate(timeZone: calendar.timeZone) {
                goTo(day: date)
            } else {
                goToToday()
            }
        case .tasks:
            DiagnosticsRecorder.shared.record("mac.deepLink", "tasks")
            isTasksPaneVisible = true
            focus = .tasks
        case .newTask:
            DiagnosticsRecorder.shared.record("mac.deepLink", "newTask")
            isTasksPaneVisible = true
            focus = .tasks
            openNewTaskEditor()
        case .task(let id):
            DiagnosticsRecorder.shared.record("mac.deepLink", "task")
            isTasksPaneVisible = true
            focus = .tasks
            guard let task = try? database?.task(id: id.uuidString.lowercased()), task.deletedAt == nil else {
                statusMessage = "Task not found on this device"
                return
            }
            selection = .task(task.id)
            editorTask = task
        case .project(let id):
            DiagnosticsRecorder.shared.record("mac.deepLink", "project")
            guard let project = try? database?.project(id: id.uuidString.lowercased()), project.deletedAt == nil else {
                isProjectsOpen = true
                statusMessage = "Project not found on this device"
                return
            }
            projectEditor = project
        case .settings:
            DiagnosticsRecorder.shared.record("mac.deepLink", "settings")
            openSettings(.server)
        }
    }
}
