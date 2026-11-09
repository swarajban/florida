import FloridaKit
import SwiftUI

/// The right-hand task list: Inbox first (with its triage count), then each category's open
/// tasks; empty categories stay as one collapsed line. Keeps the selected row scrolled into view
/// as `j` / `k` move it.
struct TaskPaneView: View {
    @Environment(AppModel.self) private var model

    static let width: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tasks")
                    .font(.headline)
                if model.focus == .tasks {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Text("\(model.openTasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    model.perform(.newTask)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New task (C)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.taskGroups) { group in
                            if group.tasks.isEmpty {
                                TaskGroupHeader(group: group)
                            } else {
                                Section {
                                    ForEach(group.tasks) { task in
                                        row(task, in: group)
                                    }
                                } header: {
                                    TaskGroupHeader(group: group)
                                }
                            }
                        }
                        if model.openTasks.isEmpty {
                            ContentUnavailableView(
                                "No open tasks", systemImage: "checkmark.circle",
                                description: Text("Press C to add one."))
                        }
                    }
                    .padding(.bottom, 8)
                    .animation(.easeOut(duration: 0.15), value: model.openTasks.map(\.id))
                }
                .onChange(of: model.selection) { _, selection in
                    if let selection, selection.isTask {
                        proxy.scrollTo(selection)
                    }
                }
            }
        }
        .frame(width: Self.width)
    }

    private func row(_ task: TaskItem, in group: CategoryTaskGroup) -> some View {
        let item = ItemID.task(task.id)
        let suggestion = group.isInbox ? model.suggestedCategory(for: task) : nil
        let tint = group.category?.tint ?? .defaultCategory
        return TaskRowView(
            task: task, state: model.scheduleState(for: task),
            tint: tint,
            isSelected: model.selection == item, isFocused: model.focus == .tasks,
            isUntriaged: group.isInbox, suggestion: suggestion,
            calendar: model.calendar
        ) {
            if let suggestion { model.move(task, to: suggestion) }
        }
        .id(item)
        .transition(model.completingTaskIds.contains(task.id) ? .bloomFold(tint) : .opacity)
        .contextMenu {
            TaskActionsMenu(task: task)
        }
        .onTapGesture(count: 2) {
            model.select(item, in: .tasks)
            model.editSelection()
        }
        .onTapGesture {
            model.select(item, in: .tasks)
        }
    }
}

/// A category's header: color, name and count. Inbox reads "3 to triage"; an empty category is
/// a dimmed collapsed line.
struct TaskGroupHeader: View {
    let group: CategoryTaskGroup

    var body: some View {
        let isEmpty = group.tasks.isEmpty
        HStack(spacing: 6) {
            if group.isInbox {
                Image(systemName: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(group.category?.tint ?? .defaultCategory)
                    .frame(width: 8, height: 8)
            }
            Text(group.name)
                .font(.subheadline.weight(isEmpty ? .regular : .semibold))
            if isEmpty {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if group.isInbox, !isEmpty {
                Text("\(group.tasks.count) to triage")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Text("\(group.tasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isEmpty ? Color.secondary : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, isEmpty ? 3 : 6)
        .background(.bar)
    }
}
