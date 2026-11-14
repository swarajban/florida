import AppKit
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
///
/// Every control shows its key (`TaskEditorKey`). An open task comes up with the keyboard in no
/// field, so the keys act at once: Space marks it done, `d` opens the due date, `p` opens the
/// priority selector. Escape leaves a field, and then the keys act.
struct TaskEditorSheet: View {
    @Environment(AppModel.self) private var model
    @State private var draft: TaskItem
    @State private var somedayIntent: Bool? = nil
    @State private var dateEdits: Set<TaskDateField> = []
    @State private var hasDue: Bool
    @State private var dueAt: Date
    @State private var hasStart: Bool
    @State private var startAt: Date
    @State private var hasPinnedStart: Bool
    @State private var pinnedStart: Date
    @State private var sourceURL: String
    @State private var sourceTitle: String
    /// The "Add a time" boxes once the user has touched them; until then each follows its date.
    @State private var dueTimeChoice: Bool?
    @State private var startTimeChoice: Bool?
    private let original: TaskItem
    /// Not in the store yet: titled "New task", shows the AI section, and saves as "Added".
    @State private var isNew: Bool
    @FocusState private var focus: TextFocus?
    @State private var keyboard = TaskEditorKeyboard()
    @State private var openField: TaskEditorKey?
    @State private var saveError: String?

    /// The text fields a key can put the keyboard in.
    private enum TextFocus {
        case title, notes, duration, sourceURL, sourceTitle
    }

    init(task: TaskItem, isNew: Bool, calendar: Calendar) {
        let today = calendar.startOfDay(for: Date())
        let defaultDue = TaskDay.defaultDue(now: Date(), calendar: calendar)
        let nextHour = Calendar.autoupdatingCurrent.date(bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600)) ?? Date()
        _draft = State(initialValue: task)
        _hasDue = State(initialValue: task.dueAt != nil)
        _dueAt = State(initialValue: task.dueAt ?? defaultDue)
        _hasStart = State(initialValue: task.startAt != nil)
        _startAt = State(initialValue: task.startAt ?? today)
        _hasPinnedStart = State(initialValue: task.pinnedStart != nil)
        _pinnedStart = State(initialValue: task.pinnedStart ?? nextHour)
        _sourceURL = State(initialValue: task.source?.url ?? "")
        _sourceTitle = State(initialValue: task.source?.title ?? "")
        original = task
        _isNew = State(initialValue: isNew)
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
                        .overlay(alignment: .trailing) { Keycap(TaskEditorKey.markDone.keycap) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(hasEdits && (recurrenceValidationMessage != nil || sourceValidationMessage != nil))
                .help("Completes the task and closes the editor")
                .padding([.horizontal, .top], 20)
            }
            Form {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("task-save-error")
                }
                if !isNew, !original.isOpen {
                    Button("Reopen", systemImage: "arrow.uturn.backward.circle") {
                        var task = preparedTask
                        task.completedAt = nil
                        task.completedMinutes = 0
                        guard model.save(task, original: original, somedayIntent: somedayIntent, dateEdits: dateEdits, undoLabel: "Reopened \(AppModel.quoted(task.title))") else {
                            saveError = model.statusMessage ?? "The task could not be reopened."
                            return
                        }
                        model.editorTask = nil
                    }
                }
                if isNew {
                    AIParseSection(apply: apply)
                }
                Section(isNew ? "New task" : "Task") {
                    TextField(text: $draft.title) {
                        keyLabel("Title", .title)
                    }
                    .focused($focus, equals: .title)
                    .accessibilityIdentifier("task-title")
                    TextField(text: notes, axis: .vertical) {
                        keyLabel("Notes", .notes)
                    }
                    .focused($focus, equals: .notes)
                    .accessibilityIdentifier("task-notes")
                    .lineLimit(3...8)
                }
                Section("Dates") {
                    MacDateField("Start", date: dateSelection($startAt, field: .start), isOn: dateEnabled($hasStart, field: .start), hasTime: startHasTime,
                                 key: TaskEditorKey.start.keycap, isPresented: showing(.start), identifier: "task-start",
                                 onDismiss: leaveField, dayOnly: { TaskDay.notBefore(on: $0, calendar: model.taskListCalendar) })
                    LabeledContent {
                        HStack {
                            MacDateField("Due", date: dateSelection($dueAt, field: .due), isOn: dateEnabled($hasDue, field: .due), hasTime: dueHasTime,
                                         isPresented: showing(.due), identifier: "task-due", showsLabel: false,
                                         onDismiss: leaveField, dayOnly: { TaskDay.due(on: $0, calendar: model.taskListCalendar) })
                            VStack(alignment: .leading, spacing: 2) {
                                Toggle("Someday", isOn: someday)
                                    .toggleStyle(.checkbox)
                                    .accessibilityIdentifier("task-someday")
                                Text("No due date")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        keyLabel("Due", .due)
                    }
                    if !hasDue && !hasStart && !hasPinnedStart && !draft.someday {
                        Text("Choose a due or start date, or Someday, to finish date triage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("task-date-triage-warning")
                    }
                    MacChoiceField("Deadline", selection: deadline,
                                   options: [DeadlineType.soft, .hard].map { MacChoice($0, $0.displayName) },
                                   key: TaskEditorKey.deadline.keycap, isPresented: showing(.deadline),
                                   identifier: "task-deadline", onDismiss: leaveField)
                    .disabled(!hasDue)
                }
                .environment(\.calendar, model.taskListCalendar)
                .environment(\.timeZone, model.taskListCalendar.timeZone)
                Section {
                    MacChoiceField("Category", selection: $draft.categoryId,
                                   options: model.orderedCategories.map { MacChoice($0.id, $0.name) },
                                   key: TaskEditorKey.category.keycap, isPresented: showing(.category),
                                   identifier: "task-category", preservesOrder: true, onDismiss: leaveField,
                                   create: { model.createCategory(name: $0)?.id })
                    LabeledContent {
                        HStack {
                            TextField("Minutes", value: $draft.durationMinutes, format: .number)
                                .labelsHidden()
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .focused($focus, equals: .duration)
                                .accessibilityIdentifier("task-duration")
                            Stepper("Minutes", value: $draft.durationMinutes, in: 5...960, step: 5)
                                .labelsHidden()
                            Text(DateText.duration(minutes: draft.durationMinutes))
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        keyLabel("Duration", .duration)
                    }
                    MacChoiceField("Priority", selection: $draft.priority,
                                   options: Priority.allCases.map { MacChoice($0, $0.displayName) },
                                   key: TaskEditorKey.priority.keycap, isPresented: showing(.priority),
                                   identifier: "task-priority", onDismiss: leaveField)
                    MacChoiceField("Context", selection: $draft.context,
                                   options: TaskContext.allCases.map { MacChoice($0, $0.displayName) },
                                   key: TaskEditorKey.context.keycap, isPresented: showing(.context),
                                   identifier: "task-context", onDismiss: leaveField)
                    MacChoiceField("Project", selection: $draft.projectId, options: projectChoices,
                                   key: TaskEditorKey.project.keycap, isPresented: showing(.project),
                                   identifier: "task-project", onDismiss: leaveField)
                    MacChoiceField("Attention", selection: $draft.attention,
                                   options: [MacChoice(TaskAttention?.none, defaultAttentionLabel)]
                                       + TaskAttention.allCases.map { MacChoice(TaskAttention?.some($0), $0.displayName) },
                                   key: TaskEditorKey.attention.keycap, isPresented: showing(.attention),
                                   identifier: "task-attention", onDismiss: leaveField)
                    .help("Work that can run in parallel shares an hour with up to two other such tasks.")
                    MacDateField("Pinned start", date: dateSelection($pinnedStart, field: .pin), isOn: dateEnabled($hasPinnedStart, field: .pin), hasTime: .constant(true),
                                 key: TaskEditorKey.pinnedStart.keycap, isPresented: showing(.pinnedStart),
                                 identifier: "task-pinned-start", onDismiss: leaveField, requiresTime: true)
                }
                TaskRecurrenceSection(
                    recurrence: $draft.recurrence,
                    anchorDate: hasDue ? dueAt : (hasStart ? startAt : nil),
                    defaultTimeZone: recurrenceTimeZone, wasRecurring: original.recurrence != nil)
                Section("Source") {
                    TextField("Source URL", text: $sourceURL)
                        .focused($focus, equals: .sourceURL)
                        .accessibilityIdentifier("task-source-url")
                    TextField("Source title (optional)", text: $sourceTitle)
                        .focused($focus, equals: .sourceTitle)
                        .accessibilityIdentifier("task-source-title")
                    if let source = editedSource {
                        HStack {
                            Button {
                                if let url = source.openURL { model.open(url: url) }
                            } label: {
                                Label("Open source", systemImage: source.symbolName)
                            }
                            .accessibilityIdentifier("task-open-source")
                            Spacer()
                            Button("Remove source") {
                                sourceURL = ""
                                sourceTitle = ""
                            }
                            .accessibilityIdentifier("task-remove-source")
                        }
                    }
                    if let message = sourceValidationMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            #if DEBUG
            HeldKeyDiagnostics(keys: ["t"])
            #endif
            Divider()
            HStack {
                Button {
                    model.editorTask = nil
                } label: {
                    KeyLabel("Cancel", key: "esc")
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Field key: search choices · ↑ ↓ then ↩ · esc leaves without changing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Spacer()
                Button {
                    save()
                } label: {
                    KeyLabel(isNew ? "Add Task" : "Save", key: "↩")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || recurrenceValidationMessage != nil || sourceValidationMessage != nil)
            }
            .padding()
        }
        .frame(width: 560, height: min(720, model.mainWindow?.contentLayoutRect.height ?? 720))
        .background(TaskEditorKeyMonitor(keyboard: keyboard, shortcutRepeats: model.shortcutRepeats,
                                        startsUnfocused: true, onPress: handle,
                                         onPriority: { draft.priority = $0 }))
        .onChange(of: startAt) { keepDueAfterStart() }
        .onChange(of: hasStart) { keepDueAfterStart() }
        .onChange(of: hasDue) { keepDueAfterStart() }
        #if DEBUG
        .onChange(of: draft.title) { model.applyEditorTestSyncIfNeeded() }
        #endif
    }

    private func keyLabel(_ title: String, _ key: TaskEditorKey) -> KeyLabel {
        KeyLabel(title, key: key.keycap)
    }

    /// One of the editor's keys. Text keys focus their fields; choice and date keys open selectors.
    private func handle(_ press: TaskEditorKey.Press) {
        switch press.key {
        case .markDone:
            if !isNew, original.isOpen {
                markDone()
            }
        case .title:
            focus = .title
        case .notes:
            focus = .notes
        case .duration:
            focus = .duration
        case .start, .due, .pinnedStart, .category, .priority, .context, .project, .attention:
            focus = nil
            openField = press.key
        case .deadline:
            guard hasDue else { return }
            openField = .deadline
        }
    }

    private func showing(_ field: TaskEditorKey) -> Binding<Bool> {
        Binding(get: { openField == field }, set: { presented in
            if presented {
                openField = field
            } else if openField == field {
                openField = nil
            }
        })
    }

    private func leaveField() {
        focus = nil
        keyboard.dropFocus()
    }

    private var projectChoices: [MacChoice<String?>] {
        var choices = [MacChoice(String?.none, "None")]
        if let id = draft.projectId, model.project(id: id) == nil || model.project(id: id)?.deletedAt != nil {
            choices.append(MacChoice(String?.some(id), "Deleted project"))
        }
        return choices + model.projectSections.flatMap(\.projects).map { MacChoice(String?.some($0.id), $0.name) }
    }

    /// A start that reaches or passes the due date leaves no time for the task, so the due date
    /// moves to the day after the start, in the row right below. Run when the start changes and
    /// when either date is switched on; a due date typed in earlier than the start is left alone.
    private func keepDueAfterStart() {
        guard hasStart, hasDue else { return }
        let adjusted = TaskDay.due(dueAt, notBefore: startAt, calendar: model.taskListCalendar)
        if adjusted != dueAt {
            dateEdits.insert(.due)
        }
        dueAt = adjusted
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
            set: {
                dateEdits.insert(.due)
                somedayIntent = false
                draft.someday = false
                draft.deadlineType = $0
            })
    }

    /// On when the due date carries a time. Without one the date picker moves the day and keeps
    /// the whole-day clock the date already has; switching off puts the date back on its whole day.
    private var dueHasTime: Binding<Bool> {
        Binding(
            get: { dueTimeChoice ?? TaskDay.dueHasTime(dueAt, calendar: model.taskListCalendar) },
            set: { on in
                dateEdits.insert(.due)
                somedayIntent = false
                draft.someday = false
                dueTimeChoice = on
                if !on {
                    dueAt = TaskDay.due(on: dueAt, calendar: model.taskListCalendar)
                }
            })
    }

    private var startHasTime: Binding<Bool> {
        Binding(
            get: { startTimeChoice ?? TaskDay.notBeforeHasTime(startAt, calendar: model.taskListCalendar) },
            set: { on in
                dateEdits.insert(.start)
                somedayIntent = false
                draft.someday = false
                startTimeChoice = on
                if !on {
                    startAt = TaskDay.notBefore(on: startAt, calendar: model.taskListCalendar)
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

    private var editedSource: TaskSource? {
        if !isNew, sourceURL == (original.source?.url ?? ""), sourceTitle == (original.source?.title ?? "") {
            return original.source
        }
        return TaskSource.from(url: sourceURL, title: sourceTitle)
    }

    private var sourceValidationMessage: String? {
        sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editedSource != nil
            ? nil : "Enter an http, https or mailto source URL."
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
        draft.dueAt = parsed.dueAt
        if parsed.dueAt != nil || parsed.startAt != nil || parsed.pinnedStart != nil {
            draft.someday = false
        }
        draft.startAt = parsed.startAt
        draft.pinnedStart = parsed.pinnedStart
        if let local = model.editorQuickAddDraft {
            draft = local.applyingExplicitFields(to: draft, categoryId: model.editorQuickAddCategoryId)
        }
        somedayIntent = nil
        dateEdits = []
        hasDue = draft.dueAt != nil
        dueAt = draft.dueAt ?? dueAt
        hasStart = draft.startAt != nil
        startAt = draft.startAt ?? startAt
        // The parsed dates say whether they carry a time.
        dueTimeChoice = nil
        startTimeChoice = nil
        hasPinnedStart = draft.pinnedStart != nil
        pinnedStart = draft.pinnedStart ?? pinnedStart
        focus = .title
    }

    private var someday: Binding<Bool> {
        Binding(
            get: { draft.someday },
            set: { on in
                somedayIntent = on
                draft.someday = on
                if on {
                    dateEdits.formUnion([.due, .pin])
                    hasDue = false
                    hasPinnedStart = false
                    draft.deadlineType = .none
                }
            })
    }

    private func dateSelection(_ date: Binding<Date>, field: TaskDateField) -> Binding<Date> {
        Binding(get: { date.wrappedValue }, set: {
            dateEdits.insert(field)
            somedayIntent = false
            draft.someday = false
            date.wrappedValue = $0
        })
    }

    private func dateEnabled(_ enabled: Binding<Bool>, field: TaskDateField) -> Binding<Bool> {
        Binding(get: { enabled.wrappedValue }, set: {
            dateEdits.insert(field)
            somedayIntent = false
            draft.someday = false
            enabled.wrappedValue = $0
        })
    }

    /// True when a field differs from the task the sheet opened on.
    private var hasEdits: Bool {
        let due: Date? = hasDue ? dueAt : nil
        let start: Date? = hasStart ? startAt : nil
        let pinned: Date? = hasPinnedStart ? pinnedStart : nil
        return somedayIntent != nil || !dateEdits.isEmpty || draft != original || due != original.dueAt || start != original.startAt
            || pinned != original.pinnedStart || editedSource != original.source
    }

    /// The draft as it is written: title trimmed, the date rows applied, deadline type and
    /// recurrence made consistent with them.
    private var preparedTask: TaskItem {
        var task = draft
        task.source = editedSource
        if isNew || task.title != original.title {
            task.title = task.title.trimmingCharacters(in: .whitespaces)
        }
        if isNew || task.durationMinutes != original.durationMinutes {
            task.durationMinutes = max(1, task.durationMinutes)
        }
        task.dueAt = hasDue ? dueAt : nil
        task.startAt = hasStart ? startAt : nil
        task.pinnedStart = hasPinnedStart ? pinnedStart : nil
        if isNew || task.dueAt != original.dueAt || task.deadlineType != original.deadlineType {
            if task.dueAt == nil {
                task.deadlineType = .none
            } else if task.deadlineType == .none {
                task.deadlineType = .soft
            }
        }
        if original.recurrence == nil && task.recurrence != nil {
            task.prepareToEnableRecurrence()
        }
        return task
    }

    /// Mark done: saves any edits as Save would (an emptied title keeps the old one), closes, and
    /// completes through the model's Space path, so the sound, the bloom and `z` are the same.
    private func markDone() {
        var task = original
        if hasEdits {
            guard recurrenceValidationMessage == nil, sourceValidationMessage == nil else { return }
            task = preparedTask
            if task.title.isEmpty {
                task.title = original.title
            }
        }
        guard model.complete(task, savingEdits: hasEdits, original: original, somedayIntent: somedayIntent, dateEdits: dateEdits) else {
            saveError = model.statusMessage ?? "This task is no longer open. Nothing was saved."
            return
        }
        model.editorTask = nil
    }

    private func save() {
        guard recurrenceValidationMessage == nil, sourceValidationMessage == nil else { return }
        guard isNew || hasEdits else {
            model.editorTask = nil
            return
        }
        if !isNew, original.isOpen {
            do {
                guard let stored = try model.database?.task(id: original.id), stored.isOpen else {
                    model.statusMessage = "This task is no longer open"
                    saveError = model.statusMessage
                    return
                }
            } catch {
                model.statusMessage = "Could not save: \(error.localizedDescription)"
                saveError = model.statusMessage
                return
            }
        }
        let task = preparedTask
        let label = isNew ? "Added \(AppModel.quoted(task.title))" : "Edited \(AppModel.quoted(task.title))"
        guard model.save(task, original: isNew ? nil : original, somedayIntent: somedayIntent, dateEdits: dateEdits, undoLabel: label) else {
            saveError = model.statusMessage ?? "The task could not be saved."
            return
        }
        model.editorTask = nil
        if isNew {
            model.selection = .task(task.id)
            model.showGhost("Added to \(model.categoriesById[task.categoryId]?.name ?? "Inbox")")
        }
    }
}
