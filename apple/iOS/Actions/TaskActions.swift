import FloridaKit
import SwiftUI

/// Done, Done for now, Do now, Push to tomorrow and Move to… for one task, the same on a Tasks
/// row and an agenda block. `taskActions(...)` adds them as swipe actions (Done on the leading
/// edge, the rest trailing) and as a context menu; the sheets they need come from
/// `taskActionSheets(...)` on the list.
struct TaskActionTargets {
    /// Set to open the Done for now sheet.
    var doneForNow: Binding<TaskItem?>
    /// Set to open the Move to… dialog.
    var moving: Binding<TaskItem?>
}

extension View {
    func taskActions(
        _ task: TaskItem, targets: TaskActionTargets, onEdit: (() -> Void)? = nil, allowsDelete: Bool = true
    ) -> some View {
        modifier(TaskActionsModifier(task: task, targets: targets, onEdit: onEdit, allowsDelete: allowsDelete))
    }

    /// The Done for now sheet and the Move to… dialog for a list using `taskActions`.
    func taskActionSheets(doneForNow: Binding<TaskItem?>, moving: Binding<TaskItem?>) -> some View {
        sheet(item: doneForNow) { task in
            DoneForNowSheet(task: task)
        }
        .moveToDialog(task: moving)
    }
}

private struct TaskActionsModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    let targets: TaskActionTargets
    let onEdit: (() -> Void)?
    let allowsDelete: Bool

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    model.complete(task)
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .tint(.green)
                Button {
                    targets.doneForNow.wrappedValue = task
                } label: {
                    Label("Done for now", systemImage: "checkmark.circle.badge.questionmark")
                }
                .tint(.teal)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if allowsDelete {
                    Button(role: .destructive) {
                        model.delete(task)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                Button {
                    model.pushToTomorrow(task)
                } label: {
                    Label("Tomorrow", systemImage: "arrow.turn.down.right")
                }
                .tint(.orange)
                Button {
                    targets.moving.wrappedValue = task
                } label: {
                    Label("Move to…", systemImage: "folder")
                }
                .tint(.indigo)
            }
            .contextMenu {
                Button {
                    model.complete(task)
                } label: {
                    Label("Done", systemImage: "checkmark.circle")
                }
                Button {
                    targets.doneForNow.wrappedValue = task
                } label: {
                    Label("Done for now…", systemImage: "checkmark.circle.badge.questionmark")
                }
                Button {
                    model.doNow(task)
                } label: {
                    Label("Do now", systemImage: "play.circle")
                }
                Button {
                    model.pushToTomorrow(task)
                } label: {
                    Label("Push to tomorrow", systemImage: "arrow.turn.down.right")
                }
                MoveToMenu(task: task)
                if let onEdit {
                    Button(action: onEdit) {
                        Label("Edit…", systemImage: "pencil")
                    }
                }
                if allowsDelete {
                    Button(role: .destructive) {
                        model.delete(task)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
    }
}
