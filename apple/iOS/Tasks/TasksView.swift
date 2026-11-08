import FloridaKit
import SwiftUI

/// The Tasks tab: quick-add field on top, then open tasks grouped by category. Swipe right to
/// complete, left to delete, tap to edit, pull to sync.
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var quickAddText = ""
    @State private var editingTask: TaskItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    QuickAddField(text: $quickAddText, categories: model.categories, calendar: model.calendar) { draft in
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
                                .fill(Color.category(section.category))
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

    /// Open tasks grouped by category in category order; tasks of an unknown category last.
    private var sections: [TaskSection] {
        let grouped = Dictionary(grouping: model.openTasks, by: \.categoryId)
        var sections = model.categories.compactMap { category in
            grouped[category.id].map { TaskSection(id: category.id, category: category, tasks: $0) }
        }
        let known = Set(model.categories.map(\.id))
        let orphans = model.openTasks.filter { !known.contains($0.categoryId) }
        if !orphans.isEmpty {
            sections.append(TaskSection(id: "no-category", category: nil, tasks: orphans))
        }
        return sections
    }
}

/// The open tasks of one category, in `openTasks()` order.
struct TaskSection: Identifiable {
    let id: String
    let category: Category?
    let tasks: [TaskItem]

    var title: String { category?.name ?? "No category" }
}
