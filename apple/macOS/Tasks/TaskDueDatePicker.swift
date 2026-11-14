import AppKit
import FloridaKit
import SwiftUI

struct TaskDueDatePicker: ViewModifier {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    @State private var origin = SelectorOrigin()
    @State private var guardedWindow: NSWindow?

    private var presented: Binding<Bool> {
        Binding(
            get: { model.dueDateTaskId == task.id },
            set: { if !$0, model.dueDateTaskId == task.id { model.dueDateTaskId = nil } })
    }

    func body(content: Content) -> some View {
        content
            .background(SelectorOriginView(origin: origin))
            .popover(isPresented: presented, arrowEdge: .leading) {
                MacDateSelector(
                    title: "Due", current: task.dueAt ?? TaskDay.defaultDue(now: Date(), calendar: model.calendar),
                    hasTime: task.dueAt.map { TaskDay.dueHasTime($0, calendar: model.calendar) } ?? false,
                    allowsTime: true, requiresTime: false, allowsClear: false, identifier: "inbox-due-\(task.id)") { result in
                        guard case .date(let date, let hasTime) = result else { return }
                        model.setDueDate(hasTime ? date : TaskDay.due(on: date, calendar: model.calendar), for: task.id)
                    } cancel: {
                        model.dueDateTaskId = nil
                    }
                    .environment(\.calendar, model.calendar)
            }
            .onAppear { if presented.wrappedValue { updateGuard() } }
            .onChange(of: presented.wrappedValue) { updateGuard() }
            .onDisappear {
                releaseGuard()
                if model.dueDateTaskId == task.id { model.dueDateTaskId = nil }
            }
    }

    private func updateGuard() {
        if presented.wrappedValue {
            if guardedWindow == nil, let window = origin.window ?? model.mainWindow {
                SelectorWindowHost.register(window)
                guardedWindow = window
            }
        } else {
            let wasGuarded = guardedWindow != nil
            releaseGuard()
            if wasGuarded {
                Task { @MainActor in
                    await Task.yield()
                    guard model.interaction.kind == .browsing else { return }
                    model.mainWindow?.makeFirstResponder(nil)
                }
            }
        }
    }

    private func releaseGuard() {
        if let guardedWindow { SelectorWindowHost.unregister(guardedWindow) }
        guardedWindow = nil
    }
}
