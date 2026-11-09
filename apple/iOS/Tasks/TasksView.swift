import FloridaKit
import SwiftUI

/// The Tasks tab: quick-add field on top, then Inbox (with its triage count and AI chips) and
/// every other category, empty ones collapsed to their header. Swipe or long-press a row for its
/// actions (`TaskActions`, all with Undo), tap to edit, pull to sync. The toolbar adds a task and
/// opens Categories.
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var quickAddText = ""
    @State private var editor: TaskEditorRequest?
    /// The unsaved task an AI parse opened, to clear the quick-add text once it is added.
    @State private var parsedTaskId: String?
    @State private var openedLaunchSheet = false
    @State private var movingTask: TaskItem?
    @State private var doneForNowTask: TaskItem?
    @State private var path: [TasksRoute] = []

    var body: some View {
        let now = Date()
        NavigationStack(path: $path) {
            List {
                Section {
                    QuickAddField(
                        text: $quickAddText, categories: model.categories, calendar: model.calendar,
                        onSubmit: { draft, category in _ = try model.createTask(from: draft, in: category) },
                        onCreateCategory: { try model.createCategory(fromHint: $0) },
                        onParseWithAI: { text in
                            let request = try await model.parseWithAI(text)
                            parsedTaskId = request.id
                            editor = request
                        })
                        .listRowBackground(FloridaStyle.panel)
                    SyncErrorBanner()
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
                            TaskListRow(
                                task: task, now: now,
                                targets: TaskActionTargets(doneForNow: $doneForNowTask, moving: $movingTask),
                                onEdit: { editor = TaskEditorRequest(task: task, isNew: false) })
                        }
                    } header: {
                        TaskSectionHeader(section: section)
                    } footer: {
                        if section.isInbox, let reason = model.triageUnavailable, !section.tasks.isEmpty {
                            Text(reason)
                        }
                    }
                }
                Section {
                    NavigationLink(value: TasksRoute.categories) {
                        Label("Categories", systemImage: "folder")
                    }
                } footer: {
                    Text("Add a category for each project or area. Typing #Infosec in quick add files the task there, or offers to create it.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(FloridaStyle.paper)
            .navigationTitle("Tasks")
            .toolbarBackground(FloridaStyle.paper, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.showToday()
                    } label: {
                        FloridaWordmark(height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Florida")
                    .accessibilityHint("Shows today's agenda")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = TaskEditorRequest(task: model.newTaskTemplate(), isNew: true)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New task")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        path = [.categories]
                    } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .accessibilityLabel("Categories")
                }
            }
            .navigationDestination(for: TasksRoute.self) { route in
                switch route {
                case .categories: CategoriesView()
                }
            }
            .sheet(item: $editor, onDismiss: clearQuickAddIfAdded) { request in
                TaskEditorView(request: request)
            }
            .taskActionSheets(doneForNow: $doneForNowTask)
            .refreshable {
                await model.syncNow()
            }
            .onChange(of: model.categories.isEmpty, initial: true) { _, empty in
                // Screenshot runs (`-uiSheet aitask`): open a parsed draft once the demo data loads.
                #if DEBUG
                if LaunchOptions.initialSheet == "aitask", !openedLaunchSheet, !empty {
                    openedLaunchSheet = true
                    editor = DemoData.parsedTask(model: model)
                }
                #endif
            }
            .task(id: inboxKey) {
                model.requestTriageSuggestions()
            }
            .toastOverlay()
        }
    }

    /// After an AI-parsed task is added, the text it came from is done with.
    private func clearQuickAddIfAdded() {
        guard let id = parsedTaskId else { return }
        parsedTaskId = nil
        if (try? model.database?.task(id: id)) != nil {
            quickAddText = ""
        }
    }

    private var sections: [TaskSection] {
        TaskSection.sections(categories: model.categories, tasks: model.listedOpenTasks)
    }

    /// Changes whenever an Inbox task appears or is renamed, which re-runs the triage request.
    private var inboxKey: [String] {
        model.openTasks.filter { $0.categoryId == TaskCategory.inboxId }.map { "\($0.id)\n\($0.title)" }
    }
}

/// Screens pushed from the Tasks tab's toolbar.
enum TasksRoute: Hashable {
    case categories
}
