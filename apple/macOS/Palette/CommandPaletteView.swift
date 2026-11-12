import FloridaKit
import SwiftUI

/// The floating panel behind ⌘K, `c`, `/` and `m`: one text field whose meaning follows the
/// text — quick-add chips, a fuzzy-filtered command list after ">", search hits, or categories.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFieldFocused: Bool
    @State private var selection: TextSelection?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FloridaMark()
                    .frame(width: 15, height: 15)
                Text("Florida")
                Spacer()
                Text("esc to close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(FloridaStyle.panel)
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $model.palette.text, selection: $selection)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFieldFocused)
                    .onSubmit {
                        model.submitPalette()
                    }
            }
            .padding(14)
            Divider()
            switch model.palette.mode {
            case .quickAdd:
                QuickAddPreview(
                    draft: model.palette.draft, category: model.paletteCategory,
                    unknownHint: model.paletteUnknownHint, calendar: model.calendar)
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
        .onAppear {
            // The overlay's text field must be in the window before it can take focus.
            DispatchQueue.main.async {
                isFieldFocused = true
            }
        }
        .onChange(of: isFieldFocused) { _, focused in
            guard focused else { return }
            // AppKit selects all when focus arrives. Set the insertion point after that
            // update so typing appends to command/search prefixes and prefilled dates.
            DispatchQueue.main.async {
                selection = TextSelection(insertionPoint: model.palette.text.endIndex)
            }
        }
        .onChange(of: model.palette.text) {
            model.paletteTextDidChange()
        }
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
        case .quickAdd: "New task — e.g. \"Write report 2h by fri !high #work\"  (type > for commands)"
        case .command: "Run a command…"
        case .search: "Search tasks and events…"
        case .move(let taskId): "Move “\(model.tasksById[taskId]?.title ?? "task")” to…"
        case .fit(let start, let minutes): "Fill \(minutes) min free at \(DateText.time(start)) with…"
        case .eventResources: "Open an event resource…"
        }
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
