import FloridaKit
import SwiftUI

/// The text field at the top of the Tasks tab. Parses the text with `QuickAddParser` on every
/// keystroke and shows what it understood as chips; return submits the draft. A `#hint` that
/// names no category is never filed in Inbox silently: the field offers to create the category
/// (and add the task to it) or to use Inbox. Long or pasted text also offers "Parse with AI",
/// which reads it on the server and opens the result for review; return still adds it locally at
/// once. When a submit fails (no categories yet, or the local write failed) the text stays and the
/// reason shows under the field until the text changes.
struct QuickAddField: View {
    @Binding var text: String
    let categories: [TaskCategory]
    let calendar: Calendar
    /// Saves the draft, in the given category when there is one (else the hint or Inbox).
    let onSubmit: (QuickAddDraft, TaskCategory?) throws -> Void
    /// Creates the category a `#hint` asked for.
    let onCreateCategory: (String) throws -> TaskCategory
    /// Reads the text with the server's AI and opens the result; nil hides the action.
    var onParseWithAI: ((String) async throws -> Void)?
    @State private var submitError: String?
    @State private var parsing: Task<Void, Never>?

    var body: some View {
        let draft = QuickAddParser.parse(text, now: Date(), calendar: calendar)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Add a task, e.g. “Write report 2h by fri #work”", text: $text)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .onSubmit(submit)
                    .accessibilityLabel("Quick add")
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear")
                }
            }
            if let submitError {
                Label(submitError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !text.isEmpty {
                let chips = QuickAddChip.chips(for: draft, categories: categories, calendar: calendar)
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(chips) { chip in
                                Label(chip.text, systemImage: chip.symbol)
                                    .font(.caption)
                                    .foregroundStyle(chip.tint)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                        }
                    }
                }
                if let hint = unknownHint(draft), !draft.title.isEmpty {
                    unknownCategoryOffer(hint: hint, draft: draft)
                }
                if onParseWithAI != nil, Self.isLong(text) {
                    parseWithAIButton
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: text) { _, _ in
            submitError = nil
            parsing?.cancel()
            parsing = nil
        }
    }

    /// Several words, or a paste with a line break: worth a model's reading.
    static func isLong(_ text: String) -> Bool {
        text.contains(where: \.isNewline) || text.count >= 60 || text.split(whereSeparator: \.isWhitespace).count >= 9
    }

    private var parseWithAIButton: some View {
        Button {
            guard let onParseWithAI, parsing == nil else { return }
            let input = text
            parsing = Task {
                do {
                    try await onParseWithAI(input)
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled {
                        submitError = error.localizedDescription
                    }
                }
                parsing = nil
            }
        } label: {
            HStack(spacing: 6) {
                if parsing != nil {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Reading…")
                } else {
                    Label("Parse with AI", systemImage: "sparkles")
                }
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.borderless)
        .disabled(parsing != nil)
        .accessibilityHint("Reads the text on the server and opens the task for review")
    }

    private func unknownCategoryOffer(hint: String, draft: QuickAddDraft) -> some View {
        let name = CategoryPalette.name(fromHint: hint)
        return HStack(spacing: 12) {
            Button {
                attempt {
                    let category = try onCreateCategory(hint)
                    try onSubmit(draft, category)
                }
            } label: {
                Label("Create category “\(name)”", systemImage: "folder.badge.plus")
            }
            Button("Use Inbox") {
                var inInbox = draft
                inInbox.categoryHint = nil
                attempt { try onSubmit(inInbox, nil) }
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.borderless)
    }

    /// The draft's `#hint` when it matches no category.
    private func unknownHint(_ draft: QuickAddDraft) -> String? {
        guard let hint = draft.categoryHint, QuickAddTaskBuilder.matchCategory(hint: hint, in: categories) == nil
        else { return nil }
        return hint
    }

    private func submit() {
        let draft = QuickAddParser.parse(text, now: Date(), calendar: calendar)
        guard !draft.title.isEmpty else { return }
        if let hint = unknownHint(draft) {
            submitError = "No category matches #\(hint). Create it or use Inbox."
            return
        }
        attempt { try onSubmit(draft, nil) }
    }

    /// Runs a submit; clears the field on success, keeps the text and shows why on failure.
    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            text = ""
            submitError = nil
        } catch {
            submitError = error.localizedDescription
        }
    }
}
