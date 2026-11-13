import FloridaKit
import SwiftUI

/// Sheet to add or edit a project: name, next step, status, category, whether it runs in parallel,
/// the time held for it each week, and notes. An existing project also lists its open tasks, each
/// opening the task editor, and can be deleted. Editing works on a copy written back with Save;
/// Cancel discards. Errors show in place; nothing waits on the server.
struct ProjectEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Project
    @State private var saveError: String?
    @State private var deleting: Project?
    @State private var taskEditor: TaskEditorRequest?
    @FocusState private var nameFocused: Bool
    private let original: Project
    private let isNew: Bool

    init(request: ProjectEditorRequest) {
        original = request.project
        isNew = request.isNew
        _draft = State(initialValue: request.project)
    }

    var body: some View {
        let now = Date()
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .focused($nameFocused)
                        .accessibilityIdentifier("project-name")
                } footer: {
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("project-save-error")
                    }
                }

                Section("Next step") {
                    TextField("The one thing to do next", text: nextStep, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("project-next-step")
                }

                Section {
                    Picker("Status", selection: $draft.status) {
                        ForEach(ProjectStatus.listOrder, id: \.self) { status in
                            Label(status.label, systemImage: status.symbolName)
                                .tag(status)
                        }
                    }
                    .accessibilityIdentifier("project-status")
                    Picker("Category", selection: categoryId) {
                        Text("None").tag(String?.none)
                        ForEach(categoryChoices) { category in
                            Text(category.name).tag(String?.some(category.id))
                        }
                    }
                    .accessibilityIdentifier("project-category")
                } footer: {
                    Text(draft.status.footnote)
                }

                Section {
                    Toggle(isOn: $draft.parallel) {
                        Label("Parallel", systemImage: PlanText.parallelSymbol)
                    }
                    .accessibilityIdentifier("project-parallel")
                } footer: {
                    Text(PlanText.parallelFootnote)
                }

                Section {
                    Picker("Weekly time", selection: weeklyMinutes) {
                        Text("None").tag(Int?.none)
                        ForEach(weeklyChoices, id: \.self) { minutes in
                            Text(Formatting.spokenDuration(minutes: minutes)).tag(Int?.some(minutes))
                        }
                    }
                    .accessibilityIdentifier("project-weekly-time")
                } footer: {
                    Text(PlanText.weeklyFootnote)
                }

                Section("Notes") {
                    TextField("Notes", text: notes, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("project-notes")
                }

                if !isNew {
                    Section("Open tasks") {
                        if openTasks.isEmpty {
                            Text("No open tasks.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(openTasks) { task in
                                Button {
                                    taskEditor = TaskEditorRequest(task: task, isNew: false)
                                } label: {
                                    TaskRow(task: task, summary: summary(of: task, now: now), now: now, calendar: model.calendar)
                                }
                                .accessibilityIdentifier("project-task-\(task.id)")
                                .accessibilityHint("Edits the task")
                            }
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            deleting = original
                        } label: {
                            Label("Delete Project", systemImage: "trash")
                        }
                        .accessibilityIdentifier("project-delete")
                        .projectDeleteConfirmation($deleting) {
                            dismiss()
                        }
                    }
                }
            }
            .accessibilityIdentifier("project-editor")
            .navigationTitle(isNew ? "New Project" : "Edit Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("project-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        save()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("project-save")
                }
            }
            .sheet(item: $taskEditor) { request in
                TaskEditorView(request: request)
            }
            .onAppear {
                nameFocused = isNew
            }
        }
    }

    // MARK: - Bindings over optional fields

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

    /// The project's category while that category exists; one deleted since reads as None.
    private var categoryId: Binding<String?> {
        Binding(
            get: { draft.categoryId.flatMap { model.category(id: $0) }?.id },
            set: { draft.categoryId = $0 })
    }

    /// Inbox is where unfiled tasks wait, so it is offered only to a project already in it.
    private var categoryChoices: [TaskCategory] {
        model.categories.filter { !$0.isInbox || $0.id == original.categoryId }
    }

    /// Minutes held each week; nil, shown as None, holds no time.
    private var weeklyMinutes: Binding<Int?> {
        Binding(
            get: { draft.weeklyMinutes.flatMap { $0 > 0 ? $0 : nil } },
            set: { draft.weeklyMinutes = $0 })
    }

    /// One to ten hours a week, plus the amount the project came with when it is none of those
    /// (set on another device), so the picker can always show the stored value.
    private var weeklyChoices: [Int] {
        var choices = [60, 120, 180, 240, 300, 360, 480, 600]
        if let stored = original.weeklyMinutes, stored > 0, !choices.contains(stored) {
            choices.append(stored)
            choices.sort()
        }
        return choices
    }

    // MARK: - Open tasks

    private var openTasks: [TaskItem] {
        model.openTasks(in: original)
    }

    private func summary(of task: TaskItem, now: Date) -> TaskScheduleSummary {
        TaskScheduleSummary(
            task: task, placements: model.placementsByTask[task.id] ?? [],
            unscheduled: model.unscheduledByTask[task.id], now: now)
    }

    // MARK: - Saving

    private func save() {
        do {
            try model.saveProject(draft, original: isNew ? nil : original)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
