import FloridaKit
import SwiftUI

/// Edits every user-settable field of a task, or fills in a new one (⇧N, `>New task`) starting
/// from quick add's defaults. New tasks can also be described in free text and parsed by the
/// server's AI, which fills the form for confirmation. Save writes locally and closes; nothing
/// waits on the server.
struct TaskEditorSheet: View {
    @Environment(AppModel.self) private var model
    @State private var draft: TaskItem
    @State private var hasDue: Bool
    @State private var dueAt: Date
    @State private var hasStart: Bool
    @State private var startAt: Date
    @State private var hasPinnedStart: Bool
    @State private var pinnedStart: Date
    /// Not in the store yet: titled "New task", shows the AI section, and saves as "Added".
    let isNew: Bool
    @FocusState private var isTitleFocused: Bool

    init(task: TaskItem, isNew: Bool) {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let defaultDue = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: today) ?? today
        let nextHour = calendar.date(bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600)) ?? Date()
        _draft = State(initialValue: task)
        _hasDue = State(initialValue: task.dueAt != nil)
        _dueAt = State(initialValue: task.dueAt ?? defaultDue)
        _hasStart = State(initialValue: task.startAt != nil)
        _startAt = State(initialValue: task.startAt ?? today)
        _hasPinnedStart = State(initialValue: task.pinnedStart != nil)
        _pinnedStart = State(initialValue: task.pinnedStart ?? nextHour)
        self.isNew = isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isNew {
                    AIParseSection(apply: apply)
                }
                Section(isNew ? "New task" : "Task") {
                    TextField("Title", text: $draft.title)
                        .focused($isTitleFocused)
                    TextField("Notes", text: notes, axis: .vertical)
                        .lineLimit(3...8)
                    Picker("Category", selection: $draft.categoryId) {
                        ForEach(model.orderedCategories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    LabeledContent("Duration") {
                        HStack {
                            TextField("Minutes", value: $draft.durationMinutes, format: .number)
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
                    Picker("Deadline", selection: $draft.deadlineType) {
                        ForEach(DeadlineType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    OptionalDateRow(title: "Due", isOn: $hasDue, date: $dueAt)
                    OptionalDateRow(title: "Not before", isOn: $hasStart, date: $startAt)
                    OptionalDateRow(title: "Pinned start", isOn: $hasPinnedStart, date: $pinnedStart)
                }
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
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: isNew ? 700 : 540)
        .onAppear {
            isTitleFocused = !isNew || model.editorAIText == nil
        }
    }

    private var notes: Binding<String> {
        Binding(
            get: { draft.notes ?? "" },
            set: { draft.notes = $0.isEmpty ? nil : $0 })
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
        hasPinnedStart = parsed.pinnedStart != nil
        pinnedStart = parsed.pinnedStart ?? pinnedStart
        isTitleFocused = true
    }

    private func save() {
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
        let label = isNew ? "Added \(AppModel.quoted(task.title))" : "Edited \(AppModel.quoted(task.title))"
        guard model.save(task, undoLabel: label) else { return }
        model.editorTask = nil
        if isNew {
            model.selection = .task(task.id)
            model.showGhost("Added to \(model.categoriesById[task.categoryId]?.name ?? "Inbox")")
        }
    }
}

/// A checkbox that enables a date-and-time picker.
struct OptionalDateRow: View {
    let title: String
    @Binding var isOn: Bool
    @Binding var date: Date

    var body: some View {
        HStack {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
            Spacer()
            DatePicker(title, selection: $date, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .disabled(!isOn)
        }
    }
}
