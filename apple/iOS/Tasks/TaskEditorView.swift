import FloridaKit
import SwiftUI

/// Sheet for one task. Mark done sits on top, full width; editing works on a copy written back
/// with Save (or Mark done / Reopen, which also save); Cancel discards. In create mode (`isNew`,
/// from the + button or an AI parse) the same form adds the task, and an AI parse's rationale
/// shows on top for review.
struct TaskEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaskItem
    @State private var confirmingDelete = false
    @State private var saveError: String?
    @FocusState private var titleFocused: Bool
    private let original: TaskItem
    private let isNew: Bool
    private let rationale: String?

    init(task: TaskItem, isNew: Bool = false, rationale: String? = nil) {
        original = task
        self.isNew = isNew
        self.rationale = rationale
        _draft = State(initialValue: task)
    }

    init(request: TaskEditorRequest) {
        self.init(task: request.task, isNew: request.isNew, rationale: request.rationale)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let rationale, !rationale.isEmpty {
                    Section {
                        Label(rationale, systemImage: "sparkles")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("How AI read it")
                    } footer: {
                        Text("Check the fields below, then Add.")
                    }
                }
                if !isNew {
                    // Finishing is what the sheet is opened for most often, so it comes first and
                    // full width; editing fields follow and Delete stays at the very end.
                    Section {
                        if draft.completedAt == nil {
                            Button {
                                completeFromEditor()
                            } label: {
                                Label("Mark done", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityHint("Completes the task and closes the editor")
                        } else {
                            Button {
                                draft.completedAt = nil
                                draft.completedMinutes = 0
                                save()
                            } label: {
                                Label("Reopen", systemImage: "arrow.uturn.backward.circle")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Title", text: $draft.title)
                        .focused($titleFocused)
                    TextField("Notes", text: notes, axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section("Category") {
                    Picker("Category", selection: $draft.categoryId) {
                        ForEach(model.categories) { category in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.category(category))
                                    .frame(width: 10, height: 10)
                                Text(category.name)
                            }
                            .tag(category.id)
                        }
                    }
                }

                Section("Scheduling") {
                    Stepper(value: $draft.durationMinutes, in: 15...(24 * 60), step: 15) {
                        LabeledContent("Duration", value: Formatting.duration(minutes: draft.durationMinutes))
                    }
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(Priority.allCases, id: \.self) { priority in
                            Text(priority.displayName).tag(priority)
                        }
                    }
                    Picker("Deadline", selection: $draft.deadlineType) {
                        ForEach(DeadlineType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    if draft.deadlineType != .none {
                        DatePicker("Due", selection: dueAt, displayedComponents: [.date, .hourAndMinute])
                    }
                }

                Section {
                    Toggle("Earliest start", isOn: hasStart)
                    if draft.startAt != nil {
                        DatePicker("Not before", selection: startAt, displayedComponents: [.date, .hourAndMinute])
                    }
                    Toggle("Pin to a time", isOn: hasPin)
                    if draft.pinnedStart != nil {
                        DatePicker("Pinned start", selection: pinnedStart, displayedComponents: [.date, .hourAndMinute])
                    }
                } footer: {
                    Text("A pinned task is placed at exactly that time as one block; otherwise the scheduler picks the time.")
                }

                TaskRecurrenceSection(
                    recurrence: $draft.recurrence, anchorDate: draft.dueAt ?? draft.startAt,
                    defaultTimeZone: recurrenceTimeZone, wasRecurring: original.recurrence != nil)

                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label(original.recurrence == nil ? "Delete task" : "Delete and stop repeating", systemImage: "trash")
                        }
                        // On the button, so the dialog opens anchored to it.
                        .confirmationDialog(
                            original.recurrence == nil ? "Delete this task?" : "Delete this occurrence and stop repeating?",
                            isPresented: $confirmingDelete, titleVisibility: .visible
                        ) {
                            Button(original.recurrence == nil ? "Delete" : "Delete and Stop Repeating", role: .destructive) {
                                model.delete(original)
                                dismiss()
                            }
                        } message: {
                            if original.recurrence != nil {
                                Text("This and future unfinished occurrences will be removed. Completed history is kept.")
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Task" : "Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        save()
                    }
                    .disabled(trimmedTitle.isEmpty || recurrenceValidationMessage != nil)
                }
            }
            .onAppear {
                titleFocused = isNew && draft.title.isEmpty
            }
            .onChange(of: draft.deadlineType) { _, type in
                if type == .none {
                    draft.dueAt = nil
                } else if draft.dueAt == nil {
                    draft.dueAt = defaultDueDate
                }
            }
        }
    }

    // MARK: - Bindings over optional fields

    private var notes: Binding<String> {
        Binding(
            get: { draft.notes ?? "" },
            set: { draft.notes = $0.isEmpty ? nil : $0 })
    }

    private var dueAt: Binding<Date> {
        Binding(
            get: { draft.dueAt ?? defaultDueDate },
            set: { draft.dueAt = $0 })
    }

    private var hasStart: Binding<Bool> {
        Binding(
            get: { draft.startAt != nil },
            set: { draft.startAt = $0 ? (draft.startAt ?? model.calendar.startOfDay(for: Date())) : nil })
    }

    private var startAt: Binding<Date> {
        Binding(
            get: { draft.startAt ?? Date() },
            set: { draft.startAt = $0 })
    }

    private var hasPin: Binding<Bool> {
        Binding(
            get: { draft.pinnedStart != nil },
            set: { draft.pinnedStart = $0 ? (draft.pinnedStart ?? nextHour) : nil })
    }

    private var pinnedStart: Binding<Date> {
        Binding(
            get: { draft.pinnedStart ?? nextHour },
            set: { draft.pinnedStart = $0 })
    }

    // MARK: - Helpers

    private var trimmedTitle: String {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recurrenceTimeZone: String {
        let scheduleId = draft.scheduleId ?? model.categories.first(where: { $0.id == draft.categoryId })?.scheduleId
        return model.schedules.first(where: { $0.id == scheduleId })?.timeZone ?? model.calendar.timeZone.identifier
    }

    private var recurrenceValidationMessage: String? {
        original.recurrence == nil
            ? draft.recurrence?.validationMessage(asNewSeriesAt: Date())
            : draft.recurrence?.validationMessage
    }

    /// Tomorrow at 17:00, matching the quick-add parser's default clock for deadlines.
    private var defaultDueDate: Date {
        let calendar = model.calendar
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        return calendar.date(bySettingHour: 17, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// The next whole hour from now.
    private var nextHour: Date {
        let calendar = model.calendar
        let now = Date()
        let hour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        return hour
    }

    /// Saves pending edits, then completes through the model so the haptic, bloom and Undo
    /// toast match a swipe.
    private func completeFromEditor() {
        guard recurrenceValidationMessage == nil else { return }
        var task = preparedTask
        if draft != original {
            task.title = trimmedTitle.isEmpty ? original.title : trimmedTitle
            do {
                try model.save(task)
            } catch {
                saveError = error.localizedDescription
                return
            }
        }
        model.complete(task)
        dismiss()
    }

    private var preparedTask: TaskItem {
        var task = draft
        task.title = trimmedTitle
        if task.deadlineType == .none && task.recurrence == nil {
            task.dueAt = nil
        }
        if original.recurrence == nil && task.recurrence != nil {
            task.prepareToEnableRecurrence()
        }
        return task
    }

    private func save() {
        guard recurrenceValidationMessage == nil else { return }
        do {
            try model.save(preparedTask)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
