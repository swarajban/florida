import FloridaKit
import SwiftUI

/// The Tasks tab: quick-add entry on top, then Inbox (with its triage count and AI chips) and
/// every other category, empty ones collapsed to their header. Swipe or long-press a row for its
/// actions (`TaskActions`, all with Undo), tap to edit, pull to sync. The toolbar adds a task and
/// opens Projects and Categories.
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var editor: TaskEditorRequest?
    @State private var openedLaunchSheet = false
    @State private var movingTask: TaskItem?
    @State private var doneForNowTask: TaskItem?
    @State private var path: [TasksRoute] = TasksRoute.launchPath

    var body: some View {
        let now = Date()
        NavigationStack(path: $path) {
            List {
                Section {
                    Button {
                        model.showingQuickAdd = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.quickAddText.isEmpty ? "Add a task" : model.quickAddText)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                Text(model.quickAddText.isEmpty ? "Just type. Use # to choose a category." : "Continue your draft")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Quick add")
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
                        if section.isInbox, !section.tasks.isEmpty {
                            Text("Choose a category to move a task out of Inbox. A category with a ? is a suggestion—tap to accept.")
                            if let reason = model.triageUnavailable {
                                Text(reason)
                            }
                        }
                    }
                }
                Section {
                    NavigationLink(value: TasksRoute.projects) {
                        Label("Projects", systemImage: PlanText.projectSymbol)
                    }
                    .accessibilityIdentifier("tasks-projects-link")
                } footer: {
                    Text("Ongoing work bigger than one task, such as an app or a migration: active, on hold, done, or still an idea.")
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
                        model.showingQuickAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New task")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        path = [.projects]
                    } label: {
                        Image(systemName: PlanText.projectSymbol)
                    }
                    .accessibilityLabel("Projects")
                    .accessibilityIdentifier("tasks-projects")
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
                case .projects: ProjectsView()
                }
            }
            .sheet(item: $editor) { request in
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
    case projects

    /// Where the tab starts. Screenshot and UI-test runs open on Projects with `-uiSheet projects`,
    /// and with `-uiSheet project`, where `ProjectsView` then opens its editor on the first active
    /// project. Any other launch starts on the task list.
    static var launchPath: [TasksRoute] {
        switch LaunchOptions.initialSheet {
        case "projects", "project": [.projects]
        default: []
        }
    }
}
