import FloridaKit
import SwiftUI

/// A task row's context menu: the same actions as the keys, run on that task.
struct TaskActionsMenu: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    var body: some View {
        Button("Done") { act { model.perform(.complete) } }
        Button("Done for Now…") { act { model.run(.doneForNow) } }
        Button("Do Now") { act { model.run(.doNow) } }
        Button("Push to Tomorrow") { act { model.perform(.snooze) } }
        Button("Move to…") { act { model.run(.move) } }
        Button("Set due date…") { act { model.run(.setDueDate) } }
        Button("Someday") { act { model.run(.someday) } }
        Button("Why Here?") { act { model.run(.explain) } }
        Divider()
        Button("Edit…") { act { model.perform(.edit) } }
        Button("Delete") { act { model.perform(.delete) } }
    }

    /// Selects the row's task first, so the action applies to it.
    private func act(_ action: () -> Void) {
        model.select(.task(task.id), in: .tasks)
        action()
    }
}
