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
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var selectionRevision = 0
    @State private var highlightedSuggestion = 0
    @State private var dismissedSuggestions: String?
    @State private var composing = false
    @State private var showingHelp = false

    private var suggestionContext: String { "\(model.quickAddText)\u{0}\(selection.location):\(selection.length)" }

    private var suggestions: [QuickAddSuggestion] {
        guard focused, !composing, selection.length == 0, dismissedSuggestions != suggestionContext else { return [] }
        return QuickAddCompletion.suggestions(
            in: model.quickAddText, caretUTF16: selection.location, categories: model.categories)
    }

    private var draft: QuickAddDraft {
        var draft = QuickAddParser.parse(model.quickAddText, now: Date(), calendar: model.calendar)
        if draft.source?.url == model.quickAddRemovedSourceURL {
            draft.source = nil
        }
        return draft
    }

    private enum CategoryChoice: Identifiable {
        case category(TaskCategory)
        case create(String)
        case inbox(TaskCategory)

        var id: String {
            switch self {
            case .category(let category): "quick-add-category-\(category.id)"
            case .create: "quick-add-create-category"
            case .inbox: "quick-add-use-inbox"
            }
        }
    }

    private var categoryOptions: [CategoryChoice] {
        let hint = draft.categoryHint ?? ""
        let matches = model.categories.filter {
            hint.isEmpty || QuickAddTaskBuilder.normalize($0.name).contains(QuickAddTaskBuilder.normalize(hint))
        }
        var options = matches.map(CategoryChoice.category)
        if matches.isEmpty, !hint.isEmpty { options.append(.create(hint)) }
        if !hint.isEmpty, let inbox = model.inbox { options.append(.inbox(inbox)) }
        return options
    }

    private var showsCategoryChoices: Bool {
        focused && !composing && selection.length == 0 && dismissedSuggestions != suggestionContext
            && categoryToken != nil && category == nil
            && (suggestions.isEmpty || suggestions.first?.symbol == "#")
    }

    private var activeChoiceIDs: [String] {
        showsCategoryChoices ? categoryOptions.map(\.id) : suggestions.map(\.id)
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
            VStack(spacing: 0) {
                input
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .layoutPriority(1)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if categoryToken == nil || category != nil {
                            if !draft.title.isEmpty { preview }
                            destination
                        }
                        if isLongText { aiButton }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .layoutPriority(-2)
                if !activeChoiceIDs.isEmpty {
                    if showsCategoryChoices {
                        ScrollViewReader { proxy in
                            ScrollView {
                                categoryChoices.padding(.horizontal, 20)
                            }
                            .onChange(of: highlightedSuggestion) { _, index in
                                if activeChoiceIDs.indices.contains(index) { proxy.scrollTo(activeChoiceIDs[index]) }
                            }
                        }
                        .frame(maxHeight: 196)
                        .layoutPriority(-1)
                        .clipped()
                        .accessibilityIdentifier("quick-add-category-choices")
                    } else if !suggestions.isEmpty {
                        suggestionList
                    }
                }
                if focused || showingHelp {
                    symbolButtons.fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(FloridaStyle.paper)
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
#if DEBUG
                    if LaunchOptions.demoData && ProcessInfo.processInfo.arguments.contains("-uiDirectEscape") {
                        Button {
                            _ = UIApplication.shared.sendAction(#selector(QuickAddTextView.dismissQuickAddSuggestions), to: nil, from: nil, for: nil)
                        } label: {
                            Image(systemName: "escape")
                        }
                        .accessibilityLabel("Send registered Escape")
                        .accessibilityIdentifier("quick-add-test-escape")
                    }
#endif
                    actions
                }
            }
            .onAppear {
                selection = NSRange(location: model.quickAddText.utf16.count, length: 0)
                selectionRevision += 1
                focused = true
            }
            .onChange(of: activeChoiceIDs) { _, _ in highlightedSuggestion = 0 }
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
                QuickAddInput(
                    text: Bindable(model).quickAddText, focused: $focused, selection: $selection,
                    selectionRevision: selectionRevision, composing: $composing,
                    activeChoiceCount: activeChoiceIDs.count, onSubmit: submit,
                    onMoveSuggestion: moveSuggestion, onDismissSuggestions: dismissSuggestions)
                    .overlay(alignment: .topLeading) {
                        if model.quickAddText.isEmpty {
                            Text("What do you need to do?")
                                .font(.body)
                                .foregroundStyle(FloridaStyle.ink.opacity(0.65))
                                .padding(.top, 4)
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
                        selection = NSRange(location: 0, length: 0)
                        selectionRevision += 1
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("Clear draft")
                }
            }
        }
        .padding(12)
        .background(FloridaStyle.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(FloridaStyle.rule))
    }

    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        Button { complete(suggestion) } label: {
                            HStack(spacing: 10) {
                                Text(suggestion.symbol).font(.body.monospaced().weight(.semibold))
                                    .frame(width: 26)
                                Text(suggestion.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.turn.down.left").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .background(index == highlightedSuggestion ? FloridaStyle.rule : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(suggestion.id)
                        .accessibilityIdentifier("quick-add-suggestion-\(suggestion.id)")
                        .accessibilityAddTraits(index == highlightedSuggestion ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(suggestions.count) * 44, dynamicTypeSize.isAccessibilitySize ? 220 : 176))
            .onChange(of: highlightedSuggestion) { _, index in
                if suggestions.indices.contains(index) { proxy.scrollTo(suggestions[index].id) }
            }
        }
        .layoutPriority(-1)
        .accessibilityIdentifier("quick-add-suggestions")
        .overlay(alignment: .top) { Divider() }
    }

    private var symbolButtons: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(["^", "!", "#", "@", "*", "=", "~", "//"], id: \.self) { symbol in
                        Button { insert(symbol) } label: {
                            Text(symbol)
                                .font(.body.monospaced().weight(.semibold))
                                .frame(minWidth: 30, minHeight: 34)
                                .background(FloridaStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Insert \(symbol)")
                        .accessibilityIdentifier("quick-add-symbol-\(symbol)")
                    }
                }
            }
            Button { showingHelp = true } label: {
                Image(systemName: "questionmark.circle")
                    .frame(width: 30, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Smart Add help")
            .accessibilityIdentifier("quick-add-shortcut-hint")
            .popover(isPresented: $showingHelp) {
                NavigationStack {
                    ScrollView {
                        Text("^fri / ^nov 20 / ^none: due date or no due date\n\n!1 ASAP · !2 high · !3 medium · !4 low (names work too)\n\n#work: category · @home: context, not location\n\n*weekly / *every 2 weeks / *mon wed: repeat\n\n=45m: estimate · ~tomorrow: start\n\n// notes: everything after this stays literal\n\nArrows choose; Tab or Return completes; Esc closes suggestions. Plain “30m by fri” still works.")
                            .font(.callout)
                            .padding(20)
                            .accessibilityIdentifier("quick-add-help-content")
                    }
                    .navigationTitle("Smart Add")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingHelp = false }
                                .accessibilityIdentifier("quick-add-help-done")
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .onDisappear { focused = true }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private func insert(_ symbol: String) {
        guard let range = Range(selection, in: model.quickAddText) else { return }
        let needsSpace = range.lowerBound > model.quickAddText.startIndex
            && !model.quickAddText[model.quickAddText.index(before: range.lowerBound)].isWhitespace
        let insertion = (needsSpace ? " " : "") + symbol
        model.quickAddText.replaceSubrange(range, with: insertion)
        selection = NSRange(location: selection.location + insertion.utf16.count, length: 0)
        selectionRevision += 1
        dismissedSuggestions = nil
        focused = true
    }

    private func complete(_ suggestion: QuickAddSuggestion) {
        guard let result = QuickAddCompletion.complete(suggestion, in: model.quickAddText) else { return }
        model.quickAddText = result.text
        selection = NSRange(location: result.caretUTF16, length: 0)
        selectionRevision += 1
        if let categoryId = suggestion.categoryId, let chosen = model.category(id: categoryId) {
            model.quickAddCategory = chosen
            model.quickAddCategoryHint = draft.categoryHint
        }
        dismissedSuggestions = categoryToken != nil && category == nil ? nil : suggestionContext
        focused = true
    }

    private func moveSuggestion(_ offset: Int) {
        let count = activeChoiceIDs.count
        guard count > 0 else { return }
        highlightedSuggestion = (highlightedSuggestion + offset + count) % count
    }

    private func submit() {
        if showsCategoryChoices {
            let options = categoryOptions
            guard !options.isEmpty else { return }
            selectCategoryOption(options[min(highlightedSuggestion, options.count - 1)], completing: true)
            return
        }
        let choices = suggestions
        if !choices.isEmpty {
            complete(choices[min(highlightedSuggestion, choices.count - 1)])
        } else {
            add()
        }
    }

    private func dismissSuggestions() {
        if activeChoiceIDs.isEmpty { focused = false }
        else { dismissedSuggestions = suggestionContext }
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
                                .accessibilityIdentifier("quick-add-chip-\(chip.id)")
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
            ForEach(Array(categoryOptions.enumerated()), id: \.element.id) { index, option in
                Button { selectCategoryOption(option) } label: {
                    HStack(spacing: 10) {
                        switch option {
                        case .category(let category):
                            Circle().fill(Color.category(category)).frame(width: 8, height: 8)
                            Text(category.name).lineLimit(1)
                        case .create(let hint):
                            Label("Create “\(CategoryPalette.name(fromHint: hint))”", systemImage: "folder.badge.plus")
                        case .inbox:
                            Text("Use Inbox").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.turn.down.left").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
                    .background(index == highlightedSuggestion ? FloridaStyle.rule : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .id(option.id)
                .accessibilityAddTraits(index == highlightedSuggestion ? .isSelected : [])
                .accessibilityIdentifier(option.id)
            }
        }
        .buttonStyle(.plain)
    }

    private func selectCategoryOption(_ option: CategoryChoice, completing: Bool = false) {
        switch option {
        case .category(let category):
            if completing, let token = categoryToken {
                let caret = NSRange(token, in: model.quickAddText).upperBound
                if let suggestion = QuickAddCompletion.suggestions(
                    in: model.quickAddText, caretUTF16: caret, categories: model.categories
                ).first(where: { $0.categoryId == category.id }) {
                    complete(suggestion)
                    return
                }
            }
            choose(category)
        case .create(let hint):
            do { choose(try model.createCategory(fromHint: hint)) }
            catch { self.error = error.localizedDescription }
        case .inbox(let category):
            choose(category)
        }
    }

    private var actions: some View {
        Group {
            Button {
                guard let category else { return }
                review(TaskEditorRequest(
                    task: QuickAddTaskBuilder.makeTask(from: draft, category: category, now: Date()), isNew: true))
            } label: {
                Label("Details", systemImage: "slider.horizontal.3")
            }
            .disabled(!canAdd)
            Button(action: add) {
                Label("Add task", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdd)
            .accessibilityIdentifier("quick-add-save")
        }
        .labelStyle(.iconOnly)
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
            selection = NSRange(location: min(selection.location, model.quickAddText.utf16.count), length: 0)
            selectionRevision += 1
        }
        model.quickAddCategory = category
        model.quickAddCategoryHint = draft.categoryHint
        dismissedSuggestions = suggestionContext
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
                    request.task = draft.applyingExplicitFields(
                        to: request.task,
                        categoryId: draft.categoryHint != nil || model.quickAddCategory != nil ? chosen.id : nil)
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
    @Binding var selection: NSRange
    var selectionRevision: Int
    @Binding var composing: Bool
    var activeChoiceCount: Int
    private var hasSuggestions: Bool { activeChoiceCount > 0 }
    var onSubmit: () -> Void
    var onMoveSuggestion: (Int) -> Void
    var onDismissSuggestions: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> QuickAddTextView {
        let view = QuickAddTextView()
        view.delegate = context.coordinator
        view.pasteDelegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.returnKeyType = .done
        view.enablesReturnKeyAutomatically = true
        view.accessibilityLabel = "Quick add"
        view.accessibilityIdentifier = "quick-add-input"
        return view
    }

    func updateUIView(_ view: QuickAddTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        if view.markedTextRange == nil, view.text != text { view.text = text }
        let location = min(selection.location, text.utf16.count)
        let range = NSRange(location: location, length: min(selection.length, text.utf16.count - location))
        if view.markedTextRange == nil, context.coordinator.appliedSelectionRevision != selectionRevision {
            context.coordinator.appliedSelectionRevision = selectionRevision
            if view.selectedRange != range { view.selectedRange = range }
            view.scrollRangeToVisible(range)
        }
        view.activeChoiceCount = activeChoiceCount
        view.onComplete = onSubmit
        view.onMoveSuggestion = onMoveSuggestion
        view.onDismissSuggestions = onDismissSuggestions
        view.font = .preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection)
        view.textColor = .label
        if focused, !view.isFirstResponder { view.becomeFirstResponder() }
        if !focused, view.isFirstResponder { view.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: QuickAddTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let lineHeight = uiView.font?.lineHeight ?? 20
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let inset = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let minimumHeight = lineHeight + inset
        let maximumHeight = min(lineHeight * (hasSuggestions ? 1 : 5) + inset, max(minimumHeight, proposal.height ?? .infinity))
        return CGSize(width: width, height: min(maximumHeight, max(minimumHeight, size.height)))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var parent: QuickAddInput
        var isUpdating = false
        var appliedSelectionRevision: Int?
        private var isPasting = false
        init(_ parent: QuickAddInput) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.composing = textView.markedTextRange != nil
            parent.selection = textView.selectedRange
            parent.text = textView.text
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isUpdating else { return }
            parent.composing = textView.markedTextRange != nil
            parent.selection = textView.selectedRange
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard textView.markedTextRange == nil else { return true }
            if text == "\n", !isPasting {
                parent.onSubmit()
                return false
            }
            if text == "\t", !isPasting, parent.hasSuggestions {
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
            parent.selection = view.selectedRange
            parent.text = view.text
            let from = view.position(from: view.beginningOfDocument, offset: start)!
            let to = view.position(from: from, offset: attributedString.length)!
            return view.textRange(from: from, to: to)!
        }
    }
}

private final class QuickAddTextView: UITextView {
    private let reportsCaretGeometry = LaunchOptions.demoData && ProcessInfo.processInfo.arguments.contains("-uiCaptureGeometry")
    private var caretViewportSize = CGSize.zero
    private var escapeProbe = (count: 0, choices: 0, focused: false)
    var activeChoiceCount = 0
    private var hasSuggestions: Bool { activeChoiceCount > 0 }
    var onComplete: (() -> Void)?
    var onMoveSuggestion: ((Int) -> Void)?
    var onDismissSuggestions: (() -> Void)?

    override var accessibilityLabel: String? {
        get {
            guard reportsCaretGeometry else { return super.accessibilityLabel }
            let keys = "escape=\(escapeProbe.count),before=\(escapeProbe.choices),focused=\(escapeProbe.focused),now=\(activeChoiceCount),marked=\(markedTextRange != nil),first=\(isFirstResponder)"
            guard isFirstResponder, let selectedTextRange, let window else { return "Quick add|\(keys)" }
            let caret = convert(caretRect(for: selectedTextRange.end), to: window)
            return "Quick add|\(caret.minX)|\(caret.minY)|\(caret.width)|\(caret.height)|\(keys)"
        }
        set { super.accessibilityLabel = newValue }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != caretViewportSize {
            caretViewportSize = bounds.size
            if isFirstResponder, selectedRange.location != NSNotFound { scrollRangeToVisible(selectedRange) }
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        guard markedTextRange == nil else { return super.keyCommands }
        let handledInputs = hasSuggestions
            ? [UIKeyCommand.inputEscape, UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\t"]
            : [UIKeyCommand.inputEscape]
        var commands = (super.keyCommands ?? []).filter {
            !$0.modifierFlags.isEmpty || !handledInputs.contains($0.input ?? "")
        }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissQuickAddSuggestions))
        escape.wantsPriorityOverSystemBehavior = true
        commands.insert(escape, at: 0)
        if hasSuggestions {
            for (input, action) in [
                (UIKeyCommand.inputUpArrow, #selector(previousSuggestion)),
                (UIKeyCommand.inputDownArrow, #selector(nextSuggestion)),
                ("\t", #selector(completeSuggestion)),
            ] {
                let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        return commands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(dismissQuickAddSuggestions) { return markedTextRange == nil }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc fileprivate func dismissQuickAddSuggestions() {
        guard markedTextRange == nil else { return }
        if reportsCaretGeometry { escapeProbe = (escapeProbe.count + 1, activeChoiceCount, isFirstResponder) }
        onDismissSuggestions?()
    }

    @objc private func previousSuggestion() {
        guard markedTextRange == nil else { return }
        onMoveSuggestion?(-1)
    }
    @objc private func nextSuggestion() {
        guard markedTextRange == nil else { return }
        onMoveSuggestion?(1)
    }
    @objc private func completeSuggestion() {
        guard markedTextRange == nil else { return }
        onComplete?()
    }
}
