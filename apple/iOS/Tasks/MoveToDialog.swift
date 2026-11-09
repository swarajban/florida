import FloridaKit
import SwiftUI

/// "Move to…" as a confirmation dialog listing the other categories, for swipe actions (which
/// cannot hold a menu). Context menus use `MoveToMenu` instead.
struct MoveToDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var task: TaskItem?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Move to…",
            isPresented: Binding(get: { task != nil }, set: { if !$0 { task = nil } }),
            titleVisibility: .visible,
            presenting: task
        ) { task in
            ForEach(model.categories.filter { $0.id != task.categoryId }) { category in
                Button(category.name) {
                    model.move(task, to: category)
                }
            }
        } message: { task in
            Text(task.title)
        }
    }
}

/// "Move to…" as a submenu of a context menu.
struct MoveToMenu: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    var body: some View {
        Menu {
            ForEach(model.categories.filter { $0.id != task.categoryId }) { category in
                Button(category.name) {
                    model.move(task, to: category)
                }
            }
        } label: {
            Label("Move to…", systemImage: "folder")
        }
    }
}

extension View {
    func moveToDialog(task: Binding<TaskItem?>) -> some View {
        modifier(MoveToDialog(task: task))
    }
}
