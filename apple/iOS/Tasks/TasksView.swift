import FloridaKit
import SwiftUI

/// The Tasks tab: quick-add field on top, then open tasks grouped by project. Swipe right to
/// complete, left to delete, tap to edit, pull to sync.
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var quickAddText = ""
    @State private var editingTask: TaskItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    QuickAddField(text: $quickAddText, projects: model.projects, calendar: model.calendar) { draft in
                        model.createTask(from: draft)
                    }
                    if model.needsSetup {
                        Label("Not connected. Add the server URL and token in Settings.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if model.openTasks.isEmpty {
                        Text("No open tasks.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.tasks) { task in
                            TaskRow(
                                task: task,
                                summary: TaskScheduleSummary(task: task, placements: model.placementsByTask[task.id] ?? []),
                                now: Date(),
                                calendar: model.calendar)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingTask = task
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    model.complete(task)
                                } label: {
                                    Label("Complete", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.delete(task)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.project(section.project))
                                .frame(width: 10, height: 10)
                            Text(section.title)
                            Spacer()
                            Text("\(section.tasks.count)")
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Tasks")
            .sheet(item: $editingTask) { task in
                TaskEditorView(task: task)
            }
            .refreshable {
                await model.syncNow()
            }
        }
    }

    /// Open tasks grouped by project in project order; tasks of an unknown project last.
    private var sections: [TaskSection] {
        let grouped = Dictionary(grouping: model.openTasks, by: \.projectId)
        var sections = model.projects.compactMap { project in
            grouped[project.id].map { TaskSection(id: project.id, project: project, tasks: $0) }
        }
        let known = Set(model.projects.map(\.id))
        let orphans = model.openTasks.filter { !known.contains($0.projectId) }
        if !orphans.isEmpty {
            sections.append(TaskSection(id: "no-project", project: nil, tasks: orphans))
        }
        return sections
    }
}

/// The open tasks of one project, in `openTasks()` order.
struct TaskSection: Identifiable {
    let id: String
    let project: Project?
    let tasks: [TaskItem]

    var title: String { project?.name ?? "No project" }
}
