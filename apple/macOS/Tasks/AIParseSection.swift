import FloridaKit
import SwiftUI

/// The new-task editor's "Describe it" section: free or pasted text sent to the server's
/// `parse-task` AI. The result is shown with the AI's rationale and only fills the form when
/// "Use this" is pressed. Quick add's local parser stays the instant default; this is for text
/// too long or loose for it.
struct AIParseSection: View {
    @Environment(AppModel.self) private var model
    @Binding var state: ParseState
    let apply: (TaskDraft) -> Void
    @State private var text = ""
    @FocusState private var isTextFocused: Bool

    enum ParseState {
        case idle, parsing
        case parsed(TaskDraft)
        case failed(String)

        var hasReview: Bool {
            if case .parsed = self { return true }
            return false
        }
    }

    var body: some View {
        Section {
            TextField("Describe the task, or paste an email or notes…", text: $text, axis: .vertical)
                .lineLimit(2...6)
                .focused($isTextFocused)
            HStack {
                Button {
                    parse()
                } label: {
                    Label("Parse with AI", systemImage: "sparkles")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsing)
                if isParsing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Text("⌘↩")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            switch state {
            case .idle, .parsing:
                EmptyView()
            case .parsed(let draft):
                TaskDraftCard(draft: draft, categoryName: categoryName(for: draft))
                HStack {
                    Spacer()
                    Button("Discard") {
                        state = .idle
                    }
                    Button("Use this") {
                        apply(draft)
                        state = .idle
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Describe it")
        }
        .onAppear {
            if let pending = model.editorAIText {
                model.editorAIText = nil
                text = pending
                parse()
            } else {
                isTextFocused = true
            }
        }
    }

    private var isParsing: Bool {
        if case .parsing = state { return true }
        return false
    }

    private func categoryName(for draft: TaskDraft) -> String {
        draft.categoryId.flatMap { model.categoriesById[$0]?.name } ?? model.inboxCategory?.name ?? "Inbox"
    }

    private func parse() {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "demoData"),
           UserDefaults.standard.bool(forKey: "uiInteractionAIReply") {
            state = .parsing
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                state = .parsed(TaskDraft(
                    title: "Parsed audit review", notes: "Synthetic review", durationMinutes: 90,
                    priority: .high, rationale: "Synthetic UI proposal", context: .errand,
                    projectId: model.projects.first?.id, attention: .shared))
            }
            return
        }
        #endif
        guard let client = model.aiClient else {
            state = .failed("Connect to the server in Settings first")
            return
        }
        state = .parsing
        Task {
            do {
                let parsed = try await client.parseTask(input)
                state = .parsed(parsed)
            } catch SyncError.http(let status, _) where status == 503 {
                state = .failed("AI isn't set up on the server")
            } catch {
                state = .failed(AppModel.describe(error))
            }
        }
    }
}

/// What the AI understood: the fields it would fill, then why.
struct TaskDraftCard: View {
    let draft: TaskDraft
    let categoryName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.title)
                .font(.headline)
            Text(fields.joined(separator: " · "))
                .font(.caption)
            if let notes = draft.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text(draft.rationale)
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var fields: [String] {
        let calendar = Calendar.autoupdatingCurrent
        var fields = [DateText.duration(minutes: draft.durationMinutes), draft.priority.displayName, categoryName]
        if let minChunk = draft.minChunkMinutes {
            fields.append("chunks ≥ \(DateText.duration(minutes: minChunk))")
        }
        if let dueAt = draft.dueAt {
            fields.append("\(draft.deadlineType == .hard ? "Due" : "By") \(DateText.dayAndTime(dueAt, calendar: calendar))")
        }
        if let startAt = draft.startAt {
            fields.append("After \(DateText.day(startAt, calendar: calendar))")
        }
        if let pinnedStart = draft.pinnedStart {
            fields.append("At \(DateText.dayAndTime(pinnedStart, calendar: calendar))")
        }
        return fields
    }
}
