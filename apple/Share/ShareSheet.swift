import FloridaKit
import SwiftUI

struct ShareSheet: View {
    @Bindable var model: ShareCaptureModel
    let add: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?

    private var suggestions: [QuickAddSuggestion] {
        guard focused, !model.literalTitle,
              case .selection(let range) = selection?.indices, range.isEmpty else { return [] }
        return QuickAddCompletion.suggestions(
            in: model.text, caretUTF16: range.lowerBound.utf16Offset(in: model.text), categories: model.categories)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Task", text: Binding(get: { model.text }, set: model.edit), selection: $selection, axis: .vertical)
                        .focused($focused)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("share-input")
                    Text(model.literalTitle ? "Page title is literal. Editing enables Smart Add symbols." : "Smart Add: #category · ^date · ^someday · =30m · // notes")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Task preview").font(.caption).foregroundStyle(.secondary)
                        Text(model.draft.title).font(.headline).accessibilityIdentifier("share-preview")
                        ForEach(QuickAddChip.chips(for: model.draft, categories: model.categories, calendar: model.calendar).filter { $0.id != "category" }) { chip in
                            Label(chip.text, systemImage: chip.symbol).font(.callout).foregroundStyle(chip.tint)
                        }
                        if let notes = model.draft.notes { Text(notes).font(.caption).accessibilityIdentifier("share-notes") }
                        if let source = model.draft.source {
                            Label(source.title, systemImage: source.symbolName)
                                .font(.callout).accessibilityIdentifier("share-source")
                            Text(source.url).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(FloridaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                    Menu {
                        ForEach(model.categories) { category in
                            Button(category.name) { model.selectedCategoryID = category.id }
                        }
                    } label: {
                        Label(model.category?.name ?? (model.categoryID == TaskCategory.inboxId ? "Inbox" : "Choose a category"), systemImage: "folder")
                    }
                    .accessibilityIdentifier("share-category")
                    Text(model.goesToInbox ? "Goes to Inbox" : "Category and date decision set — skips Inbox")
                        .font(.callout).accessibilityIdentifier("share-destination")
                    if model.categoryID == nil, model.ready { Text("Choose a category before adding.").font(.caption) }
                    if focused, !model.literalTitle {
                        ForEach(suggestions.prefix(5)) { suggestion in
                            Button("\(suggestion.symbol) \(suggestion.title)") {
                                if let result = QuickAddCompletion.complete(suggestion, in: model.text) {
                                    model.edit(result.text)
                                    selection = TextSelection(insertionPoint: String.Index(utf16Offset: result.caretUTF16, in: result.text))
                                    if let id = suggestion.categoryId { model.selectedCategoryID = id }
                                }
                            }
                        }
                    }
                    if let error = model.error {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("share-error")
                    }
                }
                .padding(16)
                .disabled(model.submitted)
            }
            .background(FloridaStyle.paper)
            .navigationTitle("Add to Florida")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).disabled(model.saving).accessibilityIdentifier("share-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(!model.canAdd).accessibilityIdentifier("share-add")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
        }
    }
}
