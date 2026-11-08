import FloridaKit
import SwiftUI

/// The floating panel behind ⌘K, `c` and `/`: one text field whose meaning follows the text —
/// quick-add chips, a fuzzy-filtered command list after ">", or search hits.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $model.palette.text)
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
                QuickAddPreview(draft: model.palette.draft, category: model.paletteCategory, calendar: model.calendar)
            case .command:
                PaletteResultList(count: model.palette.commands.count, selectedIndex: model.palette.selectedIndex) { index in
                    let command = model.palette.commands[index]
                    HStack {
                        Text(command.label)
                        Spacer()
                        Text(Keymap.default.bindings(for: command).map(\.shortcutDescription).joined(separator: "  "))
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
            case .search:
                PaletteResultList(count: model.palette.searchResults.count, selectedIndex: model.palette.selectedIndex) { index in
                    let result = model.palette.searchResults[index]
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
            }
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear {
            isFieldFocused = true
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
        }
    }

    private var placeholder: String {
        switch model.palette.mode {
        case .quickAdd: "New task — e.g. \"Write report 2h by fri !high #work\"  (type > for commands)"
        case .command: "Run a command…"
        case .search: "Search tasks and events…"
        }
    }
}

/// A scrolling list of `count` rows with one highlighted; clicking a row selects and submits it.
struct PaletteResultList<Row: View>: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let selectedIndex: Int
    @ViewBuilder let row: (Int) -> Row

    var body: some View {
        if count == 0 {
            Text("No matches")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<count, id: \.self) { index in
                            row(index)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(index == selectedIndex ? Color.accentColor.opacity(0.18) : .clear)
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
