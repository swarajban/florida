import FloridaKit
import SwiftUI

/// Edits a project, or fills in a new one (N in the Projects sheet). ⌘↩ saves, as does ↩ in a
/// text field; Esc cancels. Save writes locally and closes; nothing waits on the server. When the
/// model refuses the save, the sheet stays open and says why.
struct ProjectEditorSheet: View {
    @Environment(AppModel.self) private var model
    @State private var draft: Project
    /// Not in the store when the sheet opened: titled "New project" and saved with "Add Project".
    /// Kept from then, so the sheet does not change its words while it closes on a saved project.
    @State private var isNew: Bool
    /// Why the last save was refused; cleared by the next edit.
    @State private var message: String?
    @FocusState private var isNameFocused: Bool
    /// Weekly time on offer, in minutes.
    private let weeklyChoices: [Int]

    /// Hours a week the editor offers.
    private static let weeklyHours = [1, 2, 3, 4, 5, 6, 8, 10]

    init(project: Project, isNew: Bool) {
        _draft = State(initialValue: project)
        _isNew = State(initialValue: isNew)
        // A project already holding another amount keeps it as a choice.
        var choices = Self.weeklyHours.map { $0 * 60 }
        if let minutes = project.weeklyMinutes, minutes > 0, !choices.contains(minutes) {
            choices.append(minutes)
            choices.sort()
        }
        weeklyChoices = choices
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(isNew ? "New project" : "Project") {
                    TextField("Name", text: $draft.name)
                        .focused($isNameFocused)
                        .accessibilityIdentifier("project-editor-name")
                    MacChoiceField(
                        "Status", selection: $draft.status,
                        options: ProjectStatus.listOrder.map { MacChoice($0, $0.label) },
                        identifier: "project-editor-status")
                    MacChoiceField(
                        "Category", selection: categoryChoice,
                        options: [MacChoice(String?.none, "None")] + model.orderedCategories.map {
                            MacChoice(String?.some($0.id), $0.name)
                        },
                        identifier: "project-editor-category", preservesOrder: true,
                        create: { name in
                            guard let category = model.createCategory(name: name) else { return nil }
                            return category.id
                        })
                    TextField("Next step", text: nextStep)
                        .accessibilityIdentifier("project-editor-next-step")
                    TextField("Notes", text: notes, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("project-editor-notes")
                }
                Section {
                    Toggle(isOn: $draft.parallel) {
                        Label(ProjectsText.parallel, systemImage: PlanText.parallelSymbol)
                    }
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("project-editor-parallel")
                } footer: {
                    Text(PlanText.parallelFootnote)
                }
                Section {
                    MacChoiceField(
                        "Weekly time", selection: weeklyMinutes,
                        options: [MacChoice(Int?.none, "None")] + weeklyChoices.map {
                            MacChoice(Int?.some($0), ProjectsText.weekly($0))
                        },
                        identifier: "project-editor-weekly")
                } footer: {
                    Text(PlanText.weeklyFootnote)
                }
                if !isNew {
                    openTasks
                }
            }
            .formStyle(.grouped)
            // ↩ in a text field saves, as the default button does in the task editor.
            .onSubmit(save)
            Divider()
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top])
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("project-editor-message")
            }
            HStack {
                Button("Cancel") {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("project-editor-cancel")
                Spacer()
                Text("⌘↩")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button(isNew ? "Add Project" : "Save") {
                    save()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Save (⌘↩)")
                .accessibilityIdentifier("project-editor-save")
            }
            .padding()
        }
        .frame(width: 520, height: 620)
        .onAppear {
            isNameFocused = true
        }
        .onChange(of: draft) {
            message = nil
        }
    }

    /// The project's open tasks, to read: tasks are edited in the task pane.
    private var openTasks: some View {
        Section("Open tasks") {
            let tasks = model.openTasks(in: draft)
            if tasks.isEmpty {
                Text(ProjectsText.openTasks(0))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("project-editor-no-tasks")
            } else {
                ForEach(tasks) { task in
                    HStack {
                        Text(task.title)
                            .lineLimit(1)
                        Spacer()
                        Text(DateText.duration(minutes: task.durationMinutes))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("project-editor-task-\(task.id)")
                }
            }
        }
    }

    /// No category, or one that exists: a project whose category is gone reads as "None".
    private var categoryChoice: Binding<String?> {
        Binding(
            get: { draft.categoryId.flatMap { model.categoriesById[$0] == nil ? nil : $0 } },
            set: { draft.categoryId = $0 })
    }

    private var nextStep: Binding<String> {
        Binding(
            get: { draft.nextStep ?? "" },
            set: { draft.nextStep = $0.isEmpty ? nil : $0 })
    }

    private var notes: Binding<String> {
        Binding(
            get: { draft.notes ?? "" },
            set: { draft.notes = $0.isEmpty ? nil : $0 })
    }

    /// The weekly choice, where "None" is nil.
    private var weeklyMinutes: Binding<Int?> {
        Binding(
            get: { draft.weeklyMinutes.flatMap { $0 > 0 ? $0 : nil } },
            set: { draft.weeklyMinutes = $0 })
    }

    /// Saves through the model and closes. When the model refuses, its status message is shown
    /// here and the sheet stays open.
    private func save() {
        // So the message read back below is this save's.
        model.statusMessage = nil
        // Deleted since the sheet opened (by a sync, say): saving the draft would bring it back.
        guard isNew || model.project(id: draft.id) != nil else {
            message = "This project was deleted. Nothing was saved."
            return
        }
        guard model.save(project: draft) else {
            message = model.statusMessage ?? "The project could not be saved"
            return
        }
        model.projectEditor = nil
    }

    private func cancel() {
        // A refused save left its message on the status bar too; it is about a draft that is gone.
        if message != nil {
            model.statusMessage = nil
        }
        model.projectEditor = nil
    }
}
