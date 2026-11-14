import FloridaKit
import SwiftUI

/// Sheet for one task. Mark done sits on top, full width; editing works on a copy written back
/// with Save (or Mark done / Reopen, which also save); Cancel discards. In create mode (`isNew`,
/// from the + button or an AI parse) the same form adds the task, and an AI parse's rationale
/// shows on top for review.
///
/// The two dates come right after the title, Start above Due, one row each (`TaskDateRow`):
/// finishing a task and moving its dates are what the sheet is opened for. Both are whole days
/// unless a time is added from the row's menu (see `TaskDay` for what a day without a time
/// stores). Due is on for a new task; its soft/hard choice only shows with a date. A start moved
/// to or past the due date takes the due date with it, to the day after (`setStart`).
///
/// Category, the scheduling fields, then project, attention and "Why here?" (`TaskPlanSection`)
/// follow; the pin, repeating and Delete come last.
struct TaskEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaskItem
    @State private var somedayIntent: Bool? = nil
    @State private var dateEdits: Set<TaskDateField> = []
    @State private var confirmingDelete = false
    @State private var saveError: String?
    @State private var sourceURL: String
    @State private var sourceTitle: String
    @State private var editingSource: Bool
    /// The "Add a time" switches once the user has touched them; until then each follows its date.
    @State private var dueTimeChoice: Bool?
    @State private var startTimeChoice: Bool?
    /// The "Why here?" answer, kept here so it outlives its row scrolling off screen.
    @State private var explanation = TaskPlanSection.Explanation.idle
    @FocusState private var titleFocused: Bool
    private let original: TaskItem
    private let isNew: Bool
    private let rationale: String?

    init(task: TaskItem, isNew: Bool = false, rationale: String? = nil) {
        original = task
        self.isNew = isNew
        self.rationale = rationale
        _draft = State(initialValue: task)
        _sourceURL = State(initialValue: task.source?.url ?? "")
        _sourceTitle = State(initialValue: task.source?.title ?? "")
        _editingSource = State(initialValue: task.source != nil)
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
                                // The fill is the app tint (ink), which is light in dark mode, so
                                // the label takes the paper color rather than the style's white.
                                Label("Mark done", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .foregroundStyle(FloridaStyle.paper)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(FloridaStyle.ink)
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
                                    .frame(maxWidth: .infinity)
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
                        .accessibilityIdentifier("task-notes")
                } footer: {
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section("Dates") {
                    TaskDateRow(title: "Start", identifier: "task-start", isOn: hasStart, date: startAt, hasTime: hasStartTime)
                    TaskDateRow(title: "Due", identifier: "task-due", isOn: hasDue, date: dueAt, hasTime: hasDueTime)
                    Toggle(isOn: someday) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Someday")
                            Text("No due date")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                        .accessibilityIdentifier("task-someday")
                    if draft.dueAt == nil, draft.startAt == nil, draft.pinnedStart == nil, !draft.someday {
                        Text("Date decision pending. Choose a due date, start date, pinned time, or Someday to finish triage.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("task-date-decision-pending")
                    }
                    if hasDue.wrappedValue {
                        Picker("Deadline", selection: Binding(
                            get: { draft.deadlineType },
                            set: {
                                dateEdits.insert(.due)
                                somedayIntent = false
                                draft.someday = false
                                draft.deadlineType = $0
                            })) {
                            ForEach([DeadlineType.soft, .hard], id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                    }
                }

                sourceSection

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
                    .accessibilityIdentifier("task-category")
                }

                Section("Scheduling") {
                    Stepper(value: $draft.durationMinutes, in: 1...(24 * 60), step: 5) {
                        LabeledContent("Duration", value: Formatting.duration(minutes: draft.durationMinutes))
                    }
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(Priority.allCases, id: \.self) { priority in
                            Text(priority.displayName).tag(priority)
                        }
                    }
                    Picker("Context", selection: $draft.context) {
                        ForEach(TaskContext.allCases, id: \.self) { context in
                            Text(context.displayName).tag(context)
                        }
                    }
                }

                TaskPlanSection(task: $draft, original: original, isNew: isNew, explanation: $explanation)

                Section {
                    Toggle("Pin to a time", isOn: hasPin)
                        .accessibilityIdentifier("task-pin")
                    if draft.pinnedStart != nil {
                        DatePicker("Pinned start", selection: pinnedStart, displayedComponents: [.date, .hourAndMinute])
                            .accessibilityIdentifier("task-pin-date")
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
                                Text("This and future unfinished occurrences will be removed. Completed history is kept. Undo restores one task only, not the repeating series.")
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("task-editor-form")
            .navigationTitle(isNew ? "New Task" : "Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("task-editor-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        save()
                    }
                    .disabled(trimmedTitle.isEmpty || recurrenceValidationMessage != nil || sourceValidationMessage != nil)
                }
            }
            .onAppear {
                InboxUIDiagnostic.record("iOS.TaskEditor.appear.enter \(inboxDiagnosticState)")
                titleFocused = isNew && draft.title.isEmpty
                InboxUIDiagnostic.record("iOS.TaskEditor.appear.exit \(inboxDiagnosticState)")
                InboxUIDiagnostic.samplePresentation("iOS.TaskEditor.appear")
            }
            .onDisappear {
                InboxUIDiagnostic.record("iOS.TaskEditor.disappear \(inboxDiagnosticState)")
                InboxUIDiagnostic.samplePresentation("iOS.TaskEditor.disappear")
            }
            .onChange(of: titleFocused) { old, new in
                InboxUIDiagnostic.record("iOS.TaskEditor.focus old=\(old) new=\(new) \(inboxDiagnosticState)")
            }
            .onChange(of: draft) { _, _ in
                InboxUIDiagnostic.record("iOS.TaskEditor.draft.changed \(inboxDiagnosticState)")
            }
        }
    }

    // MARK: - Bindings over optional fields

    private var sourceSection: some View {
        Section {
            if editingSource {
                TextField("Source URL", text: $sourceURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("task-source-url")
                TextField("Source title", text: $sourceTitle)
                    .accessibilityIdentifier("task-source-title")
                if let source = validatedSource {
                    TaskSourceButton(source: source, identifier: "task-source-open")
                }
                Button("Remove source", role: .destructive) {
                    sourceURL = ""
                    sourceTitle = ""
                    editingSource = false
                }
                .accessibilityIdentifier("task-source-remove")
            } else {
                Button("Add source", systemImage: "link") { editingSource = true }
                    .accessibilityIdentifier("task-source-add")
            }
        } header: {
            Text("Source")
        } footer: {
            if let sourceValidationMessage {
                Text(sourceValidationMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("task-source-error")
            }
        }
    }

    private var validatedSource: TaskSource? {
        if !isNew, sourceURL == (original.source?.url ?? ""), sourceTitle == (original.source?.title ?? "") {
            return original.source
        }
        return TaskSource.from(url: sourceURL, title: sourceTitle)
    }

    private var sourceValidationMessage: String? {
        guard !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return validatedSource == nil ? "Use a valid https://, http://, or mailto: URL." : nil
    }

    private var notes: Binding<String> {
        Binding(
            get: { draft.notes ?? "" },
            set: { draft.notes = $0.isEmpty ? nil : $0 })
    }

    /// On while the task has a deadline. Switching it on starts a soft one on the default day (or
    /// the date the task already carries); off clears the date.
    private var hasDue: Binding<Bool> {
        Binding(
            get: { draft.deadlineType != .none },
            set: { on in
                InboxUIDiagnostic.record("iOS.TaskEditor.hasDue.enter on=\(on) \(inboxDiagnosticState)")
                defer {
                    InboxUIDiagnostic.record("iOS.TaskEditor.hasDue.exit \(inboxDiagnosticState)")
                    InboxUIDiagnostic.samplePresentation("iOS.TaskEditor.hasDue.exit")
                }
                dateEdits.insert(.due)
                somedayIntent = false
                if on {
                    draft.someday = false
                    draft.deadlineType = .soft
                    let dueAt = draft.dueAt ?? defaultDueDate
                    // The default day may be before a start already set.
                    draft.dueAt = draft.startAt.map { TaskDay.due(dueAt, notBefore: $0, calendar: model.calendar) } ?? dueAt
                } else {
                    draft.deadlineType = .none
                    draft.dueAt = nil
                    draft.someday = false
                    dueTimeChoice = nil
                }
            })
    }

    /// The Due picker. Without a time, a new day keeps the whole-day clock the date already had
    /// (the date picker carries it over) and anything else becomes the 17:00 default.
    private var dueAt: Binding<Date> {
        Binding(
            get: { draft.dueAt ?? defaultDueDate },
            set: { date in
                InboxUIDiagnostic.record("iOS.TaskEditor.dueAt.enter epoch=\(date.timeIntervalSince1970) \(inboxDiagnosticState)")
                defer { InboxUIDiagnostic.record("iOS.TaskEditor.dueAt.exit \(inboxDiagnosticState)") }
                dateEdits.insert(.due)
                somedayIntent = false
                draft.someday = false
                let calendar = model.calendar
                let keepsClock = hasDueTime.wrappedValue || !TaskDay.dueHasTime(date, calendar: calendar)
                draft.dueAt = keepsClock ? date : TaskDay.due(on: date, calendar: calendar)
            })
    }

    private var someday: Binding<Bool> {
        Binding(
            get: { draft.someday },
            set: { on in
                InboxUIDiagnostic.record("iOS.TaskEditor.someday.enter on=\(on) \(inboxDiagnosticState)")
                defer {
                    InboxUIDiagnostic.record("iOS.TaskEditor.someday.exit \(inboxDiagnosticState)")
                    InboxUIDiagnostic.samplePresentation("iOS.TaskEditor.someday.exit")
                }
                somedayIntent = on
                draft.someday = on
                if on {
                    dateEdits.formUnion([.due, .pin])
                    draft.dueAt = nil
                    draft.pinnedStart = nil
                    draft.deadlineType = .none
                    dueTimeChoice = nil
                }
            })
    }

    /// On when the due date carries a time; switching it off puts the date back on its whole day.
    private var hasDueTime: Binding<Bool> {
        Binding(
            get: { dueTimeChoice ?? draft.dueAt.map { TaskDay.dueHasTime($0, calendar: model.calendar) } ?? false },
            set: { on in
                InboxUIDiagnostic.record("iOS.TaskEditor.hasDueTime.enter on=\(on) \(inboxDiagnosticState)")
                defer { InboxUIDiagnostic.record("iOS.TaskEditor.hasDueTime.exit \(inboxDiagnosticState)") }
                dateEdits.insert(.due)
                somedayIntent = false
                draft.someday = false
                dueTimeChoice = on
                if !on, let dueAt = draft.dueAt {
                    draft.dueAt = TaskDay.due(on: dueAt, calendar: model.calendar)
                }
            })
    }

    /// On while the task has a start date ("not before"). Switching it on starts today.
    private var hasStart: Binding<Bool> {
        Binding(
            get: { draft.startAt != nil },
            set: { on in
                InboxUIDiagnostic.record("iOS.TaskEditor.hasStart.enter on=\(on) \(inboxDiagnosticState)")
                defer { InboxUIDiagnostic.record("iOS.TaskEditor.hasStart.exit \(inboxDiagnosticState)") }
                setStart(on ? (draft.startAt ?? TaskDay.notBefore(on: Date(), calendar: model.calendar)) : nil)
                if !on {
                    startTimeChoice = nil
                }
            })
    }

    /// The Start picker; without a time the date is the start of its day.
    private var startAt: Binding<Date> {
        Binding(
            get: { draft.startAt ?? Date() },
            set: { date in
                InboxUIDiagnostic.record("iOS.TaskEditor.startAt.enter epoch=\(date.timeIntervalSince1970) \(inboxDiagnosticState)")
                defer { InboxUIDiagnostic.record("iOS.TaskEditor.startAt.exit \(inboxDiagnosticState)") }
                setStart(hasStartTime.wrappedValue ? date : TaskDay.notBefore(on: date, calendar: model.calendar))
            })
    }

    private var hasStartTime: Binding<Bool> {
        Binding(
            get: { startTimeChoice ?? draft.startAt.map { TaskDay.notBeforeHasTime($0, calendar: model.calendar) } ?? false },
            set: { on in
                InboxUIDiagnostic.record("iOS.TaskEditor.hasStartTime.enter on=\(on) \(inboxDiagnosticState)")
                defer { InboxUIDiagnostic.record("iOS.TaskEditor.hasStartTime.exit \(inboxDiagnosticState)") }
                dateEdits.insert(.start)
                somedayIntent = false
                draft.someday = false
                startTimeChoice = on
                if !on, let startAt = draft.startAt {
                    setStart(TaskDay.notBefore(on: startAt, calendar: model.calendar))
                }
            })
    }

    /// Every change to the start date goes through here: a start that reaches or passes the due
    /// date moves the due date to the day after it, in the row right below.
    private func setStart(_ start: Date?) {
        InboxUIDiagnostic.record("iOS.TaskEditor.setStart.enter epoch=\(String(describing: start?.timeIntervalSince1970)) \(inboxDiagnosticState)")
        defer { InboxUIDiagnostic.record("iOS.TaskEditor.setStart.exit \(inboxDiagnosticState)") }
        dateEdits.insert(.start)
        somedayIntent = false
        draft.someday = false
        draft.startAt = start
        if let start, let dueAt = draft.dueAt {
            let adjustedDue = TaskDay.due(dueAt, notBefore: start, calendar: model.calendar)
            if adjustedDue != dueAt {
                dateEdits.insert(.due)
            }
            draft.dueAt = adjustedDue
        }
    }

    private var hasPin: Binding<Bool> {
        Binding(
            get: { draft.pinnedStart != nil },
            set: { on in
                InboxUIDiagnostic.record("iOS.TaskEditor.hasPin.enter on=\(on) \(inboxDiagnosticState)")
                defer { InboxUIDiagnostic.record("iOS.TaskEditor.hasPin.exit \(inboxDiagnosticState)") }
                dateEdits.insert(.pin)
                somedayIntent = false
                draft.someday = false
                draft.pinnedStart = on ? (draft.pinnedStart ?? nextHour) : nil
            })
    }

    private var pinnedStart: Binding<Date> {
        Binding(
            get: { draft.pinnedStart ?? nextHour },
            set: { date in
                InboxUIDiagnostic.record("iOS.TaskEditor.pinnedStart.enter epoch=\(date.timeIntervalSince1970) \(inboxDiagnosticState)")
                defer { InboxUIDiagnostic.record("iOS.TaskEditor.pinnedStart.exit \(inboxDiagnosticState)") }
                dateEdits.insert(.pin)
                somedayIntent = false
                draft.pinnedStart = date
                draft.someday = false
            })
    }

    // MARK: - Helpers

    private var inboxDiagnosticState: String {
        "someday=\(draft.someday) intent=\(String(describing: somedayIntent)) "
            + "due=\(String(describing: draft.dueAt?.timeIntervalSince1970)) "
            + "start=\(String(describing: draft.startAt?.timeIntervalSince1970)) "
            + "pin=\(String(describing: draft.pinnedStart?.timeIntervalSince1970)) noDeadline=\(draft.deadlineType == .none) "
            + "dueTimeChoice=\(String(describing: dueTimeChoice)) startTimeChoice=\(String(describing: startTimeChoice)) "
            + "dueEdited=\(dateEdits.contains(.due)) startEdited=\(dateEdits.contains(.start)) pinEdited=\(dateEdits.contains(.pin))"
    }

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

    private var defaultDueDate: Date {
        TaskDay.defaultDue(now: Date(), calendar: model.calendar)
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
        guard recurrenceValidationMessage == nil, sourceValidationMessage == nil else { return }
        var task = preparedTask
        if task.title.isEmpty {
            task.title = original.title
        }
        guard model.complete(task, original: original, somedayIntent: somedayIntent, dateEdits: dateEdits) else {
            saveError = "This task could not be completed. It may have been deleted or completed elsewhere."
            return
        }
        dismiss()
    }

    private var preparedTask: TaskItem {
        var task = draft
        if isNew || task.title != original.title {
            task.title = trimmedTitle
        }
        task.source = validatedSource
        if isNew || task.deadlineType != original.deadlineType || task.dueAt != original.dueAt,
           task.deadlineType == .none && task.recurrence == nil {
            task.dueAt = nil
        }
        if original.recurrence == nil && task.recurrence != nil {
            task.prepareToEnableRecurrence()
        }
        if task.someday {
            task.dueAt = nil
            task.pinnedStart = nil
            task.deadlineType = .none
        }
        return task
    }

    private func save() {
        guard recurrenceValidationMessage == nil, sourceValidationMessage == nil else { return }
        do {
            try model.save(preparedTask, original: isNew ? nil : original, somedayIntent: somedayIntent, dateEdits: dateEdits)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
