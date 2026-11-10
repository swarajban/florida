import FloridaKit
import SwiftUI

/// Edits every user-settable field of a task, or fills in a new one (⇧N, `>New task`) starting
/// from quick add's defaults. New tasks can also be described in free text and parsed by the
/// server's AI, which fills the form for confirmation. Save writes locally and closes; nothing
/// waits on the server. An open task has Mark done on top, which saves any edits and completes it.
///
/// The two dates come right after the title, Start above Due: finishing a task and moving its
/// dates are what the sheet is opened for. Due is checked for a new task; its soft/hard choice
/// applies only with a date. Both are whole days; "Add a time" shows a clock for the rare task
/// that needs one (see `TaskDay` for what a day without a time stores). A start moved to or past
/// the due date takes the due date with it, to the day after (`keepDueAfterStart`). A pinned
/// start always has a time.
struct TaskEditorSheet: View {
    @Environment(AppModel.self) private var model
    @State private var draft: TaskItem
    @State private var hasDue: Bool
    @State private var dueAt: Date
    @State private var hasStart: Bool
    @State private var startAt: Date
    @State private var hasPinnedStart: Bool
    @State private var pinnedStart: Date
    /// The "Add a time" boxes once the user has touched them; until then each follows its date.
    @State private var dueTimeChoice: Bool?
    @State private var startTimeChoice: Bool?
    private let original: TaskItem
    /// Not in the store yet: titled "New task", shows the AI section, and saves as "Added".
    let isNew: Bool
    @FocusState private var isTitleFocused: Bool

    init(task: TaskItem, isNew: Bool) {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let defaultDue = TaskDay.defaultDue(now: Date(), calendar: calendar)
        let nextHour = calendar.date(bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600)) ?? Date()
        _draft = State(initialValue: task)
        _hasDue = State(initialValue: task.dueAt != nil)
        _dueAt = State(initialValue: task.dueAt ?? defaultDue)
        _hasStart = State(initialValue: task.startAt != nil)
        _startAt = State(initialValue: task.startAt ?? today)
        _hasPinnedStart = State(initialValue: task.pinnedStart != nil)
        _pinnedStart = State(initialValue: task.pinnedStart ?? nextHour)
        original = task
        self.isNew = isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isNew, original.isOpen {
                // Finishing is what the sheet is opened for most often, so it comes first and full width.
                Button {
                    markDone()
                } label: {
                    Label("Mark done", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(hasEdits && recurrenceValidationMessage != nil)
                .help("Completes the task and closes the editor")
                .padding([.horizontal, .top], 20)
            }
            Form {
                if isNew {
                    AIParseSection(apply: apply)
                }
                Section(isNew ? "New task" : "Task") {
                    TextField("Title", text: $draft.title)
                        .focused($isTitleFocused)
                    TextField("Notes", text: notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("Dates") {
                    OptionalDateRow(title: "Start", isOn: $hasStart, date: $startAt, hasTime: startHasTime)
                    OptionalDateRow(title: "Due", isOn: $hasDue, date: $dueAt, hasTime: dueHasTime)
                    Picker("Deadline", selection: deadline) {
                        ForEach([DeadlineType.soft, .hard], id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .disabled(!hasDue)
                }
                Section {
                    Picker("Category", selection: $draft.categoryId) {
                        ForEach(model.orderedCategories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    LabeledContent("Duration") {
                        HStack {
                            TextField("Minutes", value: $draft.durationMinutes, format: .number)
                                .labelsHidden()
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Stepper("Minutes", value: $draft.durationMinutes, in: 5...960, step: 5)
                                .labelsHidden()
                            Text(DateText.duration(minutes: draft.durationMinutes))
                                .foregroundStyle(.secondary)
                        }
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
                    Picker("Project", selection: $draft.projectId) {
                        Text("None").tag(String?.none)
                        if let id = draft.projectId, model.project(id: id)?.deletedAt != nil || model.project(id: id) == nil {
                            // Keeps the picker from going blank while a delete is still syncing.
                            Text("Deleted project").tag(String?.some(id))
                        }
                        ForEach(model.projectSections) { section in
                            Section(section.status.label) {
                                ForEach(section.projects) { project in
                                    Text(project.name).tag(String?.some(project.id))
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("task-project")
                    Picker("Attention", selection: $draft.attention) {
                        Text(defaultAttentionLabel).tag(TaskAttention?.none)
                        ForEach(TaskAttention.allCases, id: \.self) { attention in
                            Text(attention.displayName).tag(TaskAttention?.some(attention))
                        }
                    }
                    .help("Work that can run in parallel shares an hour with up to two other such tasks.")
                    .accessibilityIdentifier("task-attention")
                    OptionalDateRow(title: "Pinned start", isOn: $hasPinnedStart, date: $pinnedStart)
                }
                TaskRecurrenceSection(
                    recurrence: $draft.recurrence,
                    anchorDate: hasDue ? dueAt : (hasStart ? startAt : nil),
                    defaultTimeZone: recurrenceTimeZone, wasRecurring: original.recurrence != nil)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") {
                    model.editorTask = nil
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Add Task" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || recurrenceValidationMessage != nil)
            }
            .padding()
        }
        .frame(width: 560, height: 720)
        .onAppear {
            isTitleFocused = !isNew || model.editorAIText == nil
        }
        .onChange(of: startAt) { keepDueAfterStart() }
        .onChange(of: hasStart) { keepDueAfterStart() }
        .onChange(of: hasDue) { keepDueAfterStart() }
    }

    /// A start that reaches or passes the due date leaves no time for the task, so the due date
    /// moves to the day after the start, in the row right below. Run when the start changes and
    /// when either date is switched on; a due date typed in earlier than the start is left alone.
    private func keepDueAfterStart() {
        guard hasStart, hasDue else { return }
        dueAt = TaskDay.due(dueAt, notBefore: startAt, calendar: model.calendar)
    }

    private var notes: Binding<String> {
        Binding(
            get: { draft.notes ?? "" },
            set: { draft.notes = $0.isEmpty ? nil : $0 })
    }

    /// "Project's default (can run in parallel)": what the task gets without a setting of its own.
    private var defaultAttentionLabel: String {
        var unset = draft
        unset.attention = nil
        let inherited = unset.attention(in: model.project(id: draft.projectId)).displayName.lowercased()
        return draft.projectId == nil ? "Default (\(inherited))" : "Project's default (\(inherited))"
    }

    /// Soft or hard. A task with a due date always has one of the two and a task without has
    /// neither (`preparedTask` applies both), so "none" is the Due box, not a choice here.
    private var deadline: Binding<DeadlineType> {
        Binding(
            get: { draft.deadlineType == .hard ? .hard : .soft },
            set: { draft.deadlineType = $0 })
    }

    /// On when the due date carries a time. Without one the date picker moves the day and keeps
    /// the whole-day clock the date already has; switching off puts the date back on its whole day.
    private var dueHasTime: Binding<Bool> {
        Binding(
            get: { dueTimeChoice ?? TaskDay.dueHasTime(dueAt, calendar: model.calendar) },
            set: { on in
                dueTimeChoice = on
                if !on {
                    dueAt = TaskDay.due(on: dueAt, calendar: model.calendar)
                }
            })
    }

    private var startHasTime: Binding<Bool> {
        Binding(
            get: { startTimeChoice ?? TaskDay.notBeforeHasTime(startAt, calendar: model.calendar) },
            set: { on in
                startTimeChoice = on
                if !on {
                    startAt = TaskDay.notBefore(on: startAt, calendar: model.calendar)
                }
            })
    }

    private var recurrenceTimeZone: String {
        let scheduleId = draft.scheduleId ?? model.categoriesById[draft.categoryId]?.scheduleId
        return model.schedules.first(where: { $0.id == scheduleId })?.timeZone ?? model.calendar.timeZone.identifier
    }

    private var recurrenceValidationMessage: String? {
        original.recurrence == nil
            ? draft.recurrence?.validationMessage(asNewSeriesAt: Date())
            : draft.recurrence?.validationMessage
    }

    /// Fills the form from an AI-parsed draft; unknown categories fall back to Inbox.
    private func apply(_ parsed: TaskDraft) {
        draft.title = parsed.title
        draft.notes = parsed.notes
        draft.durationMinutes = max(5, parsed.durationMinutes)
        draft.minChunkMinutes = parsed.minChunkMinutes
        draft.priority = parsed.priority
        draft.deadlineType = parsed.deadlineType
        if let id = parsed.categoryId, model.categoriesById[id] != nil {
            draft.categoryId = id
        }
        hasDue = parsed.dueAt != nil
        dueAt = parsed.dueAt ?? dueAt
        hasStart = parsed.startAt != nil
        startAt = parsed.startAt ?? startAt
        // The parsed dates say whether they carry a time.
        dueTimeChoice = nil
        startTimeChoice = nil
        hasPinnedStart = parsed.pinnedStart != nil
        pinnedStart = parsed.pinnedStart ?? pinnedStart
        isTitleFocused = true
    }

    /// True when a field differs from the task the sheet opened on.
    private var hasEdits: Bool {
        let due: Date? = hasDue ? dueAt : nil
        let start: Date? = hasStart ? startAt : nil
        let pinned: Date? = hasPinnedStart ? pinnedStart : nil
        return draft != original || due != original.dueAt || start != original.startAt
            || pinned != original.pinnedStart
    }

    /// The draft as it is written: title trimmed, the date rows applied, deadline type and
    /// recurrence made consistent with them.
    private var preparedTask: TaskItem {
        var task = draft
        task.title = task.title.trimmingCharacters(in: .whitespaces)
        task.durationMinutes = max(5, task.durationMinutes)
        task.dueAt = hasDue ? dueAt : nil
        task.startAt = hasStart ? startAt : nil
        task.pinnedStart = hasPinnedStart ? pinnedStart : nil
        if task.dueAt == nil {
            task.deadlineType = .none
        } else if task.deadlineType == .none {
            task.deadlineType = .soft
        }
        if original.recurrence == nil && task.recurrence != nil {
            task.prepareToEnableRecurrence()
        }
        return task
    }

    /// Mark done: saves any edits as Save would (an emptied title keeps the old one), closes, and
    /// completes through the model's Space path, so the sound, the bloom and `u` are the same.
    private func markDone() {
        var task = original
        if hasEdits {
            guard recurrenceValidationMessage == nil else { return }
            task = preparedTask
            if task.title.isEmpty {
                task.title = original.title
            }
            guard model.save(task, undoLabel: "Edited \(AppModel.quoted(task.title))") else { return }
        }
        model.editorTask = nil
        model.complete(task)
    }

    private func save() {
        guard recurrenceValidationMessage == nil else { return }
        let task = preparedTask
        let label = isNew ? "Added \(AppModel.quoted(task.title))" : "Edited \(AppModel.quoted(task.title))"
        guard model.save(task, undoLabel: label) else { return }
        model.editorTask = nil
        if isNew {
            model.selection = .task(task.id)
            model.showGhost("Added to \(model.categoriesById[task.categoryId]?.name ?? "Inbox")")
        }
    }
}

/// A checkbox that enables a date picker. With `hasTime` the row asks for a day only, and its
/// "Add a time" box shows the clock; without it the row always has a time.
struct OptionalDateRow: View {
    let title: String
    @Binding var isOn: Bool
    @Binding var date: Date
    var hasTime: Binding<Bool>?

    var body: some View {
        HStack {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
            Spacer()
            if let hasTime {
                Toggle("Add a time", isOn: hasTime)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.secondary)
                    .disabled(!isOn)
            }
            DatePicker(
                title, selection: $date,
                displayedComponents: hasTime?.wrappedValue ?? true ? [.date, .hourAndMinute] : .date)
                .labelsHidden()
                .disabled(!isOn)
        }
    }
}
