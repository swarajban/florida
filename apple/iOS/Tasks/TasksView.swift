import FloridaKit
import SwiftUI

struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var editor: TaskEditorRequest?
    @State private var openedLaunchSheet = false
    @State private var movingTask: TaskItem?
    @State private var doneForNowTask: TaskItem?
    @State private var path: [TasksRoute] = TasksRoute.launchPath
    @State private var now = AppModel.currentTime
    @AppStorage("taskListGrouping", store: .florida) private var grouping: TaskListGrouping = .dueDate

    var body: some View {
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
                                task: task, now: now, calendar: groupingCalendar,
                                category: grouping == .dueDate && model.category(id: task.categoryId)?.isInbox == false
                                    ? model.category(id: task.categoryId) : nil,
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
            .accessibilityIdentifier("tasks-list")
            .scrollContentBackground(.hidden)
            .background(FloridaStyle.paper)
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
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
                ToolbarItem(placement: .principal) {
                    Menu {
                        Picker("Group by", selection: $grouping) {
                            ForEach(TaskListGrouping.allCases, id: \.rawValue) { option in
                                Text(option.title)
                                    .tag(option)
                                    .accessibilityIdentifier("tasks-grouping-\(option.rawValue)")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Tasks").font(.headline)
                            Image(systemName: "line.3.horizontal.decrease").font(.caption)
                        }
                    }
                    .accessibilityLabel("Task view options")
                    .accessibilityValue("Group by \(grouping.title)")
                    .accessibilityIdentifier("tasks-view-options")
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
            .task {
                while !Task.isCancelled {
                    now = model.now
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .toastOverlay()
        }
    }

    private var sections: [TaskSection] {
        grouping.sections(tasks: model.listedOpenTasks, categories: model.categories, now: now, calendar: groupingCalendar)
    }

    private var groupingCalendar: Calendar {
        var calendar = model.calendar
        if let identifier = model.userSettings?.timeZone, let timeZone = TimeZone(identifier: identifier) {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    /// Changes whenever an Inbox task appears or is renamed, which re-runs the triage request.
    private var inboxKey: [String] {
        TaskListGrouping.inboxTasks(in: model.openTasks).map { "\($0.id)\n\($0.title)" }
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
