import FloridaKit
import SwiftUI

/// The projects overlay (`g p`): every live project under its status, in the order
/// `projectSections` gives.
///
/// The sheet is its own window, so the main window's key monitor never sees its keys; they are
/// handled here. ↑ ↓ or J K move the selection, ↩ edits the selected project, N starts a new
/// one, S moves it to its next status, ⌫ deletes it after a confirmation, and Esc closes the
/// sheet. A click selects a row and a double-click edits it.
struct ProjectsSheet: View {
    @Environment(AppModel.self) private var model
    /// The selected project's id. It follows the project when S moves it to another section.
    @State private var selectedID: String?
    /// The id of the draft N opened. The store reports a saved project after the editor has
    /// closed; it is selected then.
    @State private var newProjectID: String?
    /// The project whose delete is waiting for confirmation.
    @State private var projectToDelete: Project?
    /// The sheet itself holds the keyboard, so its keys work without a click.
    @FocusState private var hasKeyboard: Bool

    var body: some View {
        @Bindable var model = model
        let sections = model.projectSections
        VStack(spacing: 0) {
            header
            Divider()
            if sections.isEmpty {
                ContentUnavailableView(
                    "No projects yet", systemImage: PlanText.projectSymbol,
                    description: Text("Press N to add one."))
                    .frame(maxHeight: .infinity)
            } else {
                list(sections)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .focusable()
        .focused($hasKeyboard)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            handle(press)
        }
        .defaultFocus($hasKeyboard, true)
        .onAppear {
            reconcileSelection(orderedProjects.map(\.id))
            hasKeyboard = true
        }
        .onChange(of: sections.flatMap(\.projects).map(\.id)) { _, ids in
            reconcileSelection(ids)
        }
        // The keyboard comes back to the list when the editor or the confirmation closes.
        .onChange(of: model.projectEditor) { _, editor in
            if editor == nil { hasKeyboard = true }
        }
        .onChange(of: projectToDelete) { _, project in
            if project == nil { hasKeyboard = true }
        }
        .sheet(item: $model.projectEditor) { project in
            ProjectEditorSheet(project: project, isNew: model.project(id: project.id) == nil)
        }
        .confirmationDialog(
            "Delete this project?",
            isPresented: Binding(
                get: { projectToDelete != nil },
                set: { if !$0 { projectToDelete = nil } }),
            titleVisibility: .visible, presenting: projectToDelete
        ) { project in
            Button("Delete Project", role: .destructive) {
                delete(project)
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { projectToDelete = nil }
        } message: { project in
            Text(deleteMessage(for: project))
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            Text("Projects")
                .font(.headline)
            Spacer()
            Button {
                newProject()
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .help("New project (N)")
            .accessibilityIdentifier("projects-new")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func list(_ sections: [ProjectSection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        ProjectSectionHeader(section: section)
                            .id(section.status)
                        ForEach(section.projects) { project in
                            row(project)
                        }
                    }
                }
                .padding(.bottom, 10)
                .animation(.easeOut(duration: 0.15), value: sections)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("projects-list")
            }
            .onChange(of: selectedID) {
                reveal(selectedID, in: sections, with: proxy)
            }
            // S moves the selected project to another section without changing the selection.
            .onChange(of: sections) {
                reveal(selectedID, in: sections, with: proxy)
            }
        }
    }

    private func row(_ project: Project) -> some View {
        ProjectRowView(
            project: project, category: project.categoryId.flatMap { model.categoriesById[$0] },
            openTaskCount: model.openTasks(in: project).count, isSelected: project.id == selectedID
        )
        .id(project.id)
        .onTapGesture(count: 2) {
            select(project)
            edit(project)
        }
        .onTapGesture {
            select(project)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                keyHint("↑ ↓  J K", "Move")
                keyHint("↩", "Edit")
                keyHint("N", "New")
                keyHint("S", "Next status")
                keyHint("⌫", "Delete")
                keyHint("Esc", "Close")
            }
            .font(.caption)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("projects-keys")
            Spacer(minLength: 0)
            Button("Done") {
                close()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("projects-done")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func keyHint(_ keys: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .monospaced()
            Text(action)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Keys

    /// One key press in the sheet. ⌘, ⌃ and ⌥ chords are left to the menus and the system; a held
    /// key repeats only the moves.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let isRepeat = press.phase != .down
        switch press.key {
        case .upArrow:
            moveSelection(by: -1)
        case .downArrow:
            moveSelection(by: 1)
        case .return:
            if !isRepeat { editSelection() }
        case .delete, .deleteForward:
            if !isRepeat { projectToDelete = selectedProject }
        case .escape:
            if !isRepeat { close() }
        default:
            // Letters match whatever Shift and Caps Lock are doing.
            switch press.characters.lowercased() {
            case "k":
                moveSelection(by: -1)
            case "j":
                moveSelection(by: 1)
            case "n":
                if !isRepeat { newProject() }
            case "s":
                if !isRepeat { cycleStatus() }
            default:
                return .ignored
            }
        }
        return .handled
    }

    // MARK: Selection

    private var orderedProjects: [Project] {
        model.projectSections.flatMap(\.projects)
    }

    private var selectedProject: Project? {
        orderedProjects.first { $0.id == selectedID }
    }

    private func select(_ project: Project) {
        selectedID = project.id
        hasKeyboard = true
    }

    /// Moves the selection through the sections as one list, stopping at either end.
    private func moveSelection(by delta: Int) {
        let ids = orderedProjects.map(\.id)
        guard !ids.isEmpty else { return }
        guard let selectedID, let index = ids.firstIndex(of: selectedID) else {
            self.selectedID = delta > 0 ? ids.first : ids.last
            return
        }
        self.selectedID = ids[min(max(index + delta, 0), ids.count - 1)]
    }

    /// Keeps a row selected as the list changes: the project N just added once the store has it,
    /// else the one already selected, else the first.
    private func reconcileSelection(_ ids: [String]) {
        if let newProjectID, ids.contains(newProjectID) {
            selectedID = newProjectID
            self.newProjectID = nil
        } else if selectedID.map({ !ids.contains($0) }) ?? true {
            selectedID = ids.first
        }
    }

    /// Scrolls the selected row into view. The first project brings its heading with it.
    private func reveal(_ id: String?, in sections: [ProjectSection], with proxy: ScrollViewProxy) {
        guard let id else { return }
        if let first = sections.first, first.projects.first?.id == id {
            proxy.scrollTo(first.status, anchor: .top)
        } else {
            proxy.scrollTo(id)
        }
    }

    // MARK: Actions

    private func editSelection() {
        if let project = selectedProject {
            edit(project)
        }
    }

    private func edit(_ project: Project) {
        model.projectEditor = project
    }

    private func newProject() {
        let draft = model.newProjectTemplate()
        newProjectID = draft.id
        model.projectEditor = draft
    }

    private func cycleStatus() {
        if let project = selectedProject {
            model.cycleStatus(of: project)
        }
    }

    /// Deletes a confirmed project and moves the selection to the row after it, or before it at
    /// the end of the list.
    private func delete(_ project: Project) {
        let ids = orderedProjects.map(\.id)
        if selectedID == project.id, let index = ids.firstIndex(of: project.id) {
            selectedID = index + 1 < ids.count ? ids[index + 1] : (index > 0 ? ids[index - 1] : nil)
        }
        projectToDelete = nil
        model.delete(project: project)
    }

    private func close() {
        model.isProjectsOpen = false
    }

    /// "“Okta rollout” has no open tasks." or what becomes of the ones it has.
    private func deleteMessage(for project: Project) -> String {
        let name = AppModel.quoted(project.name)
        switch model.openTasks(in: project).count {
        case 0: return "\(name) has no open tasks."
        case 1: return "\(name) has 1 open task. It stays, without a project."
        case let count: return "\(name) has \(count) open tasks. They stay, without a project."
        }
    }
}
