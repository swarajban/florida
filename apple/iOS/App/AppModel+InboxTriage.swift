import FloridaKit
import Foundation

extension AppModel {
    func markSomeday(_ task: TaskItem) {
        var change: (before: TaskItem, after: TaskItem)?
        guard write({ change = try $0.setTaskDateDecision(id: task.id, decision: .someday) }),
              let change else { return }
        refreshTaskDateState(change.after)
        showToast(Toast(
            message: "Moved to Someday", systemImage: "tray", style: .info,
            undo: TaskUndo(from: change.before, to: change.after)))
    }

    func setInboxDueDate(_ task: TaskItem, to date: Date) throws {
        let due = TaskDay.due(on: date, calendar: calendar)
        var change: (before: TaskItem, after: TaskItem)?
        try perform { change = try $0.setTaskDateDecision(id: task.id, decision: .due(due)) }
        guard let change else { return }
        refreshTaskDateState(change.after)
        showToast(Toast(
            message: "Due date set", systemImage: "calendar", style: .info,
            undo: TaskUndo(from: change.before, to: change.after)))
    }

    func refreshTaskDateState(_ task: TaskItem) {
        guard let index = openTasks.firstIndex(where: { $0.id == task.id }) else { return }
        openTasks[index] = task
    }

    var somedayTaskIDs: Set<String> { Set(openTasks.lazy.filter(\.someday).map(\.id)) }

    func visibleTaskPlan(_ agenda: DayAgenda, excluding somedayIDs: Set<String>) -> DayAgenda {
        var agenda = agenda
        agenda.placements.removeAll { $0.task.someday || somedayIDs.contains($0.task.id) }
        return agenda
    }
}
