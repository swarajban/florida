import FloridaKit
import SwiftUI

/// Projects, pushed from the Tasks tab: ongoing work grouped by status (Active, Thinking about,
/// On hold, Done). Tap to edit; swipe right or long-press to change the status in one gesture;
/// swipe left or the editor to delete (after a confirmation that says its tasks stay); + to add.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ProjectEditorRequest?
    @State private var deleting: Project?

    var body: some View {
        let sections = model.projectSections
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.projects) { project in
                        row(project)
                    }
                } header: {
                    header(section)
                } footer: {
                    Text(section.status.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("projects-list")
        // A status change moves the row to its new section rather than jumping there.
        .animation(.snappy, value: sections)
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView {
                    Label("No projects yet", systemImage: PlanText.projectSymbol)
                } description: {
                    Text("Keep ongoing work here, such as an app or a migration: active, on hold, done, or still an idea.")
                } actions: {
                    Button("Add Project") {
                        add()
                    }
                    .accessibilityIdentifier("projects-add-first")
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    add()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add project")
                .accessibilityIdentifier("projects-add")
            }
        }
        .sheet(item: $editing) { request in
            ProjectEditorView(request: request)
        }
        .onChange(of: model.projects.isEmpty, initial: true) { _, _ in
            #if DEBUG
            openLaunchEditor()
            #endif
        }
        .toastOverlay()
    }

    private func header(_ section: ProjectSection) -> some View {
        let count = section.projects.count
        let spoken: String = "\(section.status.label), \(count) \(count == 1 ? "project" : "projects")"
        return HStack(spacing: 6) {
            Image(systemName: section.status.symbolName)
            Text(section.status.label)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.subheadline.weight(.medium))
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("projects-section-\(section.status.rawValue)")
    }

    private func row(_ project: Project) -> some View {
        Button {
            edit(project)
        } label: {
            ProjectRow(
                project: project, category: project.categoryId.flatMap { model.category(id: $0) },
                openTaskCount: model.openTasks(in: project).count)
        }
        .accessibilityIdentifier("project-row-\(project.id)")
        .accessibilityHint("Edits the project")
        // Every other status is one swipe away; a full swipe pauses an active project and
        // resumes any other.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            ForEach(statuses(otherThan: project.status), id: \.self) { status in
                Button {
                    model.setStatus(status, of: project)
                } label: {
                    Label(status.label, systemImage: status.symbolName)
                }
                .tint(swipeTint(status))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                deleting = project
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        // On the row, so the dialog opens next to it rather than at the list's edge.
        .projectDeleteConfirmation($deleting.only(project))
        .contextMenu {
            Picker("Status", selection: statusBinding(for: project)) {
                ForEach(ProjectStatus.listOrder, id: \.self) { status in
                    Label(status.label, systemImage: status.symbolName)
                        .tag(status)
                }
            }
            Button {
                edit(project)
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleting = project
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// The project's status for the long-press menu, where picking another one sets it.
    private func statusBinding(for project: Project) -> Binding<ProjectStatus> {
        Binding(
            get: { project.status },
            set: { model.setStatus($0, of: project) })
    }

    /// The statuses a swipe offers, the likeliest first: Active to resume, else On hold to pause.
    private func statuses(otherThan current: ProjectStatus) -> [ProjectStatus] {
        [ProjectStatus.active, .onHold, .done, .thinking].filter { $0 != current }
    }

    /// Swipe-button colors, in the family the task swipes use (green finishes, orange defers).
    private func swipeTint(_ status: ProjectStatus) -> Color {
        switch status {
        case .active: .blue
        case .thinking: .indigo
        case .onHold: .orange
        case .done: .green
        }
    }

    private func add() {
        editing = ProjectEditorRequest(project: model.newProjectTemplate(), isNew: true)
    }

    private func edit(_ project: Project) {
        editing = ProjectEditorRequest(project: project, isNew: false)
    }

    #if DEBUG
    /// Screenshot runs (`-uiSheet project`): open the first active project once the demo data loads.
    private func openLaunchEditor() {
        guard LaunchOptions.initialSheet == "project", !openedLaunchEditor,
              let project = model.projectSections.first(where: { $0.status == .active })?.projects.first
        else { return }
        openedLaunchEditor = true
        edit(project)
    }
    #endif
}

#if DEBUG
/// Whether the `-uiSheet project` hook has fired. Per launch rather than per `ProjectsView`, so
/// going back to Tasks and into Projects again does not reopen the editor.
@MainActor private var openedLaunchEditor = false
#endif

/// What the project sheet shows: an existing project to edit, or an unsaved one to add.
struct ProjectEditorRequest: Identifiable {
    var project: Project
    var isNew: Bool

    var id: String { project.id }
}

extension View {
    /// Asks before deleting a project, saying what happens to its open tasks. Put it on the row
    /// or button that sets `project`: the dialog opens anchored to the view it modifies.
    func projectDeleteConfirmation(_ project: Binding<Project?>, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(ProjectDeleteConfirmation(project: project, onDeleted: onDeleted))
    }
}

private struct ProjectDeleteConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var project: Project?
    let onDeleted: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete “\(project?.name ?? "")”?",
            isPresented: $project.isPresent(),
            titleVisibility: .visible,
            presenting: project
        ) { project in
            Button("Delete Project", role: .destructive) {
                model.deleteProject(project)
                onDeleted()
            }
        } message: { project in
            let count = model.openTasks(in: project).count
            Text(count == 0 ? "It has no open tasks." : "Its \(count) open \(count == 1 ? "task stays" : "tasks stay"), without a project.")
        }
    }
}
