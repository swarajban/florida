import FloridaKit
import SwiftUI

/// The floating panel behind ⌘K, `c`, `/` and `m`: one text field whose meaning follows the
/// text — quick-add chips, a fuzzy-filtered command list after ">", search hits, or categories.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @State private var caretRect = CGRect.zero

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FloridaMark()
                    .frame(width: 15, height: 15)
                Text("Florida")
                Spacer()
                Text(model.palette.suggestions.isEmpty ? "esc to close" : "esc to dismiss suggestions")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(FloridaStyle.panel)
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                SelectorInput(
                    text: $model.palette.text, placeholder: placeholder, identifier: "palette-input",
                    command: inputCommand, isPaletteInput: true, caretUTF16: model.palette.caretUTF16,
                    caretRevision: model.palette.caretRevision,
                    selectionChanged: { selection, rect in
                        if caretRect != rect { caretRect = rect }
                        model.updatePaletteSuggestions(caretUTF16: selection.location, selectionLength: selection.length)
                    })
                    .frame(height: 24)
                    .anchorPreference(key: PaletteInputAnchor.self, value: .bounds) { $0 }
            }
            .padding(14)
            Divider()
            switch model.palette.mode {
            case .quickAdd:
                QuickAddPreview(
                    draft: model.palette.draft, category: model.paletteCategory,
                    unknownHint: model.paletteUnknownHint, calendar: model.taskListCalendar)
            case .command:
                PaletteResultList(items: model.palette.commands, selectedIndex: model.palette.selectedIndex) { command in
                    HStack {
                        Text(command.label)
                        Spacer()
                        Text(MacKeymap.default.shortcut(for: command))
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
            case .search:
                PaletteResultList(items: model.palette.searchResults, selectedIndex: model.palette.selectedIndex) { result in
                    HStack {
                        Image(systemName: result.id.isTask ? "checkmark.circle" : "calendar")
                            .foregroundStyle(.secondary)
                        Text(result.title)
                            .lineLimit(1)
                        Spacer()
                        Text(result.subtitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            case .fit:
                PaletteResultList(items: model.palette.taskResults, selectedIndex: model.palette.selectedIndex) { task in
                    HStack {
                        Circle()
                            .fill(model.categoriesById[task.categoryId]?.tint ?? .defaultCategory)
                            .frame(width: 8, height: 8)
                        Text(task.title)
                            .lineLimit(1)
                        Spacer()
                        Text(DateText.duration(minutes: task.remainingMinutes))
                            .foregroundStyle(.secondary)
                    }
                }
            case .eventResources:
                PaletteResultList(items: model.palette.resourceResults, selectedIndex: model.palette.selectedIndex) { resource in
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                        Text(resource.title)
                            .lineLimit(1)
                        Spacer()
                        Text(resource.kindLabel)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("event-resource-result-\(resource.id)")
                }
            case .move(let taskId):
                PaletteResultList(items: model.palette.categoryResults, selectedIndex: model.palette.selectedIndex) { category in
                    HStack {
                        Circle()
                            .fill(category.tint)
                            .frame(width: 10, height: 10)
                        Text(category.name)
                        Spacer()
                        if model.tasksById[taskId]?.categoryId == category.id {
                            Text("current")
                                .foregroundStyle(.secondary)
                        } else if let task = model.tasksById[taskId], model.suggestedCategory(for: task)?.id == category.id {
                            Text("suggested")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(width: 600)
        .background(FloridaStyle.paper, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(FloridaStyle.rule))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .overlayPreferenceValue(PaletteInputAnchor.self) { anchor in
            GeometryReader { geometry in
                if let anchor, !model.palette.suggestions.isEmpty {
                    QuickAddSuggestionList()
                        .frame(width: 310)
                        .offset(
                            x: min(max(geometry[anchor].minX + caretRect.minX, 8), geometry.size.width - 318),
                            y: geometry[anchor].minY + caretRect.minY + 4)
                }
            }
        }
        .onChange(of: model.palette.text) {
            model.paletteTextDidChange()
        }
    }

    private func inputCommand(_ name: String) -> Bool {
        switch name {
        case "insertNewline:":
            if model.palette.suggestions.isEmpty { model.submitPalette() }
            else { model.completePaletteSuggestion() }
        case "cancelOperation:":
            if model.palette.suggestions.isEmpty { model.closePalette() }
            else { model.dismissPaletteSuggestions() }
        default: return false
        }
        return true
    }

    private var icon: String {
        switch model.palette.mode {
        case .quickAdd: "plus.circle"
        case .command: "command"
        case .search: "magnifyingglass"
        case .move: "folder"
        case .fit: "calendar.badge.plus"
        case .eventResources: "link"
        }
    }

    private var placeholder: String {
        switch model.palette.mode {
        case .quickAdd: "New task — Write report ^fri !high #work =2h  (type > for commands)"
        case .command: "Run a command…"
        case .search: "Search tasks and events…"
        case .move(let taskId): "Move “\(model.tasksById[taskId]?.title ?? "task")” to…"
        case .fit(let start, let minutes): "Fill \(minutes) min free at \(DateText.time(start)) with…"
        case .eventResources: "Open an event resource…"
        }
    }
}

private struct PaletteInputAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct QuickAddSuggestionList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.palette.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button {
                                model.palette.suggestionIndex = index
                                model.completePaletteSuggestion()
                            } label: {
                                HStack(spacing: 8) {
                                    Text(suggestion.symbol).monospaced().foregroundStyle(.secondary)
                                    Text(suggestion.title).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                                .background(index == model.palette.suggestionIndex ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .foregroundStyle(index == model.palette.suggestionIndex ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("smart-add-suggestion-\(suggestion.id)")
                            .accessibilityValue(index == model.palette.suggestionIndex ? "Highlighted" : "Not highlighted")
                            .accessibilityAddTraits(index == model.palette.suggestionIndex ? .isSelected : [])
                            .id(suggestion.id)
                        }
                    }
                    .padding(5)
                }
                .frame(height: CGFloat(min(model.palette.suggestions.count, 6)) * 34 + 10)
                .onChange(of: model.palette.suggestionIndex) { _, index in
                    if model.palette.suggestions.indices.contains(index) {
                        proxy.scrollTo(model.palette.suggestions[index].id)
                    }
                }
            }
            Divider()
            Text("↑ ↓ to move · ⇥ / ↩ to complete · esc to dismiss")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .background(FloridaStyle.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FloridaStyle.rule))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .accessibilityIdentifier("smart-add-suggestions")
    }
}

/// A scrolling list of rows with one highlighted; clicking a row selects and submits it.
///
/// Each row is handed its item, not an index to look up: a row can be drawn once more after the
/// palette has closed and emptied its results, and an index into them would then be out of range.
struct PaletteResultList<Item, Row: View>: View {
    @Environment(AppModel.self) private var model
    let items: [Item]
    let selectedIndex: Int
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        if items.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            row(item)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(index == selectedIndex ? FloridaStyle.ink.opacity(0.08) : .clear)
                                .contentShape(Rectangle())
                                .id(index)
                                .onTapGesture {
                                    model.palette.selectedIndex = index
                                    model.submitPalette()
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 340)
                .onChange(of: selectedIndex) { _, index in
                    proxy.scrollTo(index)
                }
            }
        }
    }
}
