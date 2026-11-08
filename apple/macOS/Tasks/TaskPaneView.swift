import FloridaKit
import SwiftUI

/// The right-hand task list: open tasks grouped by project. Keeps the selected row scrolled
/// into view as `j` / `k` move it.
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
                            Section {
                                ForEach(group.tasks) { task in
                                    let item = ItemID.task(task.id)
                                    TaskRowView(
                                        task: task, state: model.scheduleState(for: task),
                                        tint: group.project?.tint ?? .defaultProject,
                                        isSelected: model.selection == item, isFocused: model.focus == .tasks,
                                        calendar: model.calendar)
                                    .id(item)
                                    .onTapGesture(count: 2) {
                                        model.select(item, in: .tasks)
                                        model.editSelection()
                                    }
                                    .onTapGesture {
                                        model.select(item, in: .tasks)
                                    }
                                }
                            } header: {
                                TaskGroupHeader(group: group)
                            }
                        }
                        if model.openTasks.isEmpty {
                            ContentUnavailableView(
                                "No open tasks", systemImage: "checkmark.circle",
                                description: Text("Press C to add one."))
                        }
                    }
                    .padding(.bottom, 8)
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
}

struct TaskGroupHeader: View {
    let group: ProjectTaskGroup

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(group.project?.tint ?? .defaultProject)
                .frame(width: 8, height: 8)
            Text(group.name)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(group.tasks.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
