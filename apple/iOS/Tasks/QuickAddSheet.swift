import FloridaKit
import SwiftUI
import UIKit

/// One local-first capture surface for Tasks, Agenda and the widget. The model keeps the draft
/// across dismissals; only a successful save consumes it. AI and the full editor are optional.
struct QuickAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var focused = false
    @State private var error: String?
    @State private var parsing: Task<Void, Never>?
    @State private var editor: TaskEditorRequest?
    @State private var reviewedTaskID: String?

    private var draft: QuickAddDraft {
        var draft = QuickAddParser.parse(model.quickAddText, now: Date(), calendar: model.calendar)
        if draft.source?.url == model.quickAddRemovedSourceURL {
            draft.source = nil
        }
        return draft
    }

    private var category: TaskCategory? {
        if draft.categoryHint == nil, categoryToken != nil { return nil }
        if let chosen = model.quickAddCategory, model.quickAddCategoryHint == draft.categoryHint {
            // The store covers a newly created category before observation delivers it, but
            // unlike the retained snapshot it excludes categories deleted while capture was closed.
            return model.category(id: chosen.id)
                ?? (try? model.database?.categories())?.first { $0.id == chosen.id }
        }
        if let hint = draft.categoryHint {
            return QuickAddTaskBuilder.matchCategory(hint: hint, in: model.categories)
        }
        return model.inbox
    }

    private var canAdd: Bool { !draft.title.isEmpty && category != nil && parsing == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    input
                    if categoryToken != nil, category == nil {
                        categoryChoices
                    } else {
                        if !draft.title.isEmpty { preview }
                        destination
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    if isLongText { aiButton }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(FloridaStyle.paper)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
            .onChange(of: model.quickAddText) { _, _ in
                error = nil
                parsing?.cancel()
                parsing = nil
                let parsedSource = QuickAddParser.parse(model.quickAddText, now: Date(), calendar: model.calendar).source
                if parsedSource?.url != model.quickAddRemovedSourceURL {
                    model.quickAddRemovedSourceURL = nil
                }
                if draft.categoryHint != model.quickAddCategoryHint {
                    model.quickAddCategory = nil
                    model.quickAddCategoryHint = nil
                }
            }
            .onDisappear { parsing?.cancel() }
            .sheet(item: $editor, onDismiss: editorClosed) { request in
                TaskEditorView(request: request)
            }
        }
        .tint(FloridaStyle.ink)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                QuickAddInput(text: Bindable(model).quickAddText, focused: $focused, onSubmit: add)
                    .overlay(alignment: .topLeading) {
                        if model.quickAddText.isEmpty {
                            Text("What do you need to do?")
                                .font(.body)
                                .foregroundStyle(FloridaStyle.ink.opacity(0.65))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                if !model.quickAddText.isEmpty || model.quickAddCategory != nil {
                    Button {
                        model.quickAddText = ""
                        model.quickAddRemovedSourceURL = nil
                        model.quickAddCategory = nil
                        model.quickAddCategoryHint = nil
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("Clear draft")
                }
            }
            if model.quickAddText.isEmpty {
                Text("Try “Write update 30m tomorrow #work”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(FloridaStyle.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(FloridaStyle.rule))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.title)
                .font(.body.weight(.medium))
                .accessibilityIdentifier("quick-add-title")
            if let source = draft.source {
                HStack(spacing: 8) {
                    Label(source.title, systemImage: source.symbolName)
                        .lineLimit(2)
                    Button {
                        model.quickAddRemovedSourceURL = source.url
                        parsing?.cancel()
                        parsing = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Remove source")
                    .accessibilityIdentifier("quick-add-remove-source")
                }
                .font(.caption)
                .padding(.leading, 10)
                .background(FloridaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("quick-add-source")
            }
            let chips = QuickAddChip.chips(for: draft, categories: model.categories, calendar: model.calendar)
                .filter { $0.id != "category" }
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips) { chip in
                            Label(chip.text, systemImage: chip.symbol)
                                .font(.caption)
                                .foregroundStyle(chip.tint)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(FloridaStyle.panel, in: Capsule())
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                ForEach(model.categories) { category in
                    Button(category.name, systemImage: category.isInbox ? "tray" : "folder") {
                        choose(category)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: category?.isInbox == true ? "tray" : "folder")
                        .foregroundStyle(Color.category(category))
                    Text(category?.name ?? "Choose a category")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("quick-add-category")
            Text(model.categories.isEmpty ? "Sync your categories in Settings first. Your draft stays here."
                 : category == nil ? "Choose a category for this task."
                 : category?.isInbox == true ? "Unfiled for now. Choose a category to skip Inbox."
                 : "Goes straight here, not Inbox.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var categoryChoices: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CHOOSE A CATEGORY")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            let hint = draft.categoryHint ?? ""
            let matches = model.categories.filter {
                hint.isEmpty || QuickAddTaskBuilder.normalize($0.name).contains(QuickAddTaskBuilder.normalize(hint))
            }
            ForEach(matches) { category in
                Button { choose(category) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Color.category(category)).frame(width: 8, height: 8)
                        Text(category.name)
                        Spacer()
                        Image(systemName: "arrow.turn.down.left").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("quick-add-category-\(category.id)")
            }
            if matches.isEmpty, !hint.isEmpty {
                Button {
                    do { choose(try model.createCategory(fromHint: hint)) }
                    catch { self.error = error.localizedDescription }
                } label: {
                    Label("Create “\(CategoryPalette.name(fromHint: hint))”", systemImage: "folder.badge.plus")
                        .padding(.vertical, 12)
                }
            }
            if !hint.isEmpty, let inbox = model.inbox {
                Button("Use Inbox") { choose(inbox) }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button {
                guard let category else { return }
                review(TaskEditorRequest(
                    task: QuickAddTaskBuilder.makeTask(from: draft, category: category, now: Date()), isNew: true))
            } label: {
                Label("Details", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
            }
            .buttonStyle(.bordered)
            .disabled(!canAdd)
            Button(action: add) {
                Label("Add task", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(FloridaStyle.paper)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdd)
            .accessibilityIdentifier("quick-add-save")
        }
        .font(.subheadline.weight(.semibold))
        .controlSize(.large)
        .padding(20)
        .background(FloridaStyle.paper)
    }

    /// The parser owns only the first category token; later hashtags remain literal title text.
    private var categoryToken: Range<String.Index>? {
        let text = model.quickAddText
        if let hint = draft.categoryHint {
            let pattern = "(?<!\\S)#\(NSRegularExpression.escapedPattern(for: hint))(?!\\S)"
            return text.range(of: pattern, options: .regularExpression)
        }
        if draft.notes == nil, text == "#" || text.hasSuffix(" #") {
            return text.index(before: text.endIndex)..<text.endIndex
        }
        return nil
    }

    private func choose(_ category: TaskCategory) {
        parsing?.cancel()
        parsing = nil
        // A bare # is a launcher, not a parser token. Keep real hints in the text so resolving
        // the first one never promotes a later literal hashtag into a new category hint.
        if draft.categoryHint == nil, let range = categoryToken {
            model.quickAddText.removeSubrange(range)
            model.quickAddText = model.quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        model.quickAddCategory = category
        model.quickAddCategoryHint = draft.categoryHint
        error = nil
        focused = true
    }

    private func add() {
        guard canAdd, let category else { return }
        do { finished(try model.createTask(from: draft, in: category)) }
        catch { self.error = error.localizedDescription }
    }

    private func review(_ request: TaskEditorRequest) {
        reviewedTaskID = request.id
        focused = false
        editor = request
    }

    private func editorClosed() {
        if let id = reviewedTaskID, let task = try? model.database?.task(id: id) {
            finished(task)
        } else {
            focused = true
        }
        reviewedTaskID = nil
    }

    private func finished(_ task: TaskItem) {
        let name = model.category(id: task.categoryId)?.name ?? model.quickAddCategory?.name ?? "Inbox"
        model.quickAddText = ""
        model.quickAddRemovedSourceURL = nil
        model.quickAddCategory = nil
        model.quickAddCategoryHint = nil
        model.showToast(Toast(message: "Added to \(name)", systemImage: "checkmark.circle.fill", style: .success))
        dismiss()
    }

    private var isLongText: Bool {
        let text = model.quickAddText
        return text.contains(where: \.isNewline) || text.count >= 60 || text.split(whereSeparator: \.isWhitespace).count >= 9
    }

    private var aiButton: some View {
        Button {
            guard parsing == nil else { return }
            let text = model.quickAddText
            let parsedSource = QuickAddParser.parse(text, now: Date(), calendar: model.calendar).source
            let source = draft.source
            let sourceFreeText = QuickAddParser.removingSource(from: text)
            let aiText = draft.title == parsedSource?.title ? "\(draft.title)\n\(sourceFreeText)" : sourceFreeText
            parsing = Task {
                do {
                    var request = try await model.parseWithAI(aiText)
                    try Task.checkCancellation()
                    guard model.quickAddText == text else { return }
                    guard let chosen = category else {
                        throw LocalWriteError("Choose a current category before continuing.")
                    }
                    // Explicit filing wins over an AI guess.
                    if draft.categoryHint != nil || model.quickAddCategory != nil {
                        request.task.categoryId = chosen.id
                    }
                    request.task.source = source
                    review(request)
                } catch is CancellationError {
                    return
                } catch {
                    // parseWithAI wraps transport cancellations. An old request must not clear
                    // a newer request's handle, or that newer request could publish stale text.
                    guard !Task.isCancelled, model.quickAddText == text else { return }
                    self.error = error.localizedDescription
                }
                parsing = nil
            }
        } label: {
            Label(parsing == nil ? "Parse with AI" : "Reading…", systemImage: "sparkles")
                .font(.subheadline)
        }
        .disabled(parsing != nil || category == nil)
        .accessibilityHint("Optional. Opens the result for review before saving.")
    }
}

/// A growing text view whose Done key submits, while paste always remains an edit. SwiftUI's
/// vertical TextField inserts newlines for both, so string-diff heuristics cannot distinguish them.
private struct QuickAddInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.pasteDelegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.returnKeyType = .done
        view.enablesReturnKeyAutomatically = true
        view.accessibilityLabel = "Quick add"
        view.accessibilityIdentifier = "quick-add-input"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.font = .preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection)
        view.textColor = .label
        if focused, !view.isFirstResponder { view.becomeFirstResponder() }
        if !focused, view.isFirstResponder { view.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let lineHeight = uiView.font?.lineHeight ?? 20
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(lineHeight * 5, max(lineHeight * 2, size.height)))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var parent: QuickAddInput
        private var isPasting = false
        init(_ parent: QuickAddInput) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", !isPasting {
                parent.onSubmit()
                return false
            }
            return true
        }
        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
            performPasteOf attributedString: NSAttributedString, to textRange: UITextRange
        ) -> UITextRange {
            guard let view = textPasteConfigurationSupporting as? UITextView else { return textRange }
            // Paste can finish asynchronously after permission or an item provider resolves.
            // Mark the actual insertion, not the earlier paste(_:) action.
            isPasting = true
            defer { isPasting = false }
            let start = view.offset(from: view.beginningOfDocument, to: textRange.start)
            view.replace(textRange, withText: attributedString.string)
            parent.text = view.text
            let from = view.position(from: view.beginningOfDocument, offset: start)!
            let to = view.position(from: from, offset: attributedString.length)!
            return view.textRange(from: from, to: to)!
        }
    }
}
