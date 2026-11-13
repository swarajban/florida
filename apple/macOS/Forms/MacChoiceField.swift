import AppKit
import FloridaKit
import SwiftUI

struct MacChoice<Value: Hashable> {
    let value: Value
    let title: String

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

struct MacChoiceField<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [MacChoice<Value>]
    var key: String?
    var isPresented: Binding<Bool>?
    let identifier: String
    var showsLabel = true
    var preservesOrder = false
    var onDismiss: () -> Void = {}
    var create: ((String) -> Value?)?
    @State private var localPresented = false
    @State private var originWindow: NSWindow?
    @State private var ownsOrigin = false
    @State private var origin = SelectorOrigin()
    @State private var anchorReady = false

    init(_ title: String, selection: Binding<Value>, options: [MacChoice<Value>], key: String? = nil,
         isPresented: Binding<Bool>? = nil, identifier: String, showsLabel: Bool = true,
         preservesOrder: Bool = false, onDismiss: @escaping () -> Void = {},
         create: ((String) -> Value?)? = nil) {
        self.title = title
        _selection = selection
        self.options = options
        self.key = key
        self.isPresented = isPresented
        self.identifier = identifier
        self.showsLabel = showsLabel
        self.preservesOrder = preservesOrder
        self.onDismiss = onDismiss
        self.create = create
    }

    private var presented: Binding<Bool> { isPresented ?? $localPresented }

    private var popoverPresented: Binding<Bool> {
        Binding(get: { presented.wrappedValue && anchorReady }, set: { presented.wrappedValue = $0 })
    }

    var body: some View {
        Group {
            if showsLabel {
                LabeledContent {
                    control
                } label: {
                    HStack(spacing: 6) {
                        Text(title)
                        if let key { Keycap(key) }
                    }
                }
            } else {
                control
            }
        }
        .onChange(of: presented.wrappedValue, initial: true) { wasOpen, isOpen in
            guard wasOpen != isOpen || isOpen else { return }
            if isOpen {
                originWindow = origin.window ?? originWindow ?? NSApp.keyWindow
                if let originWindow, !ownsOrigin {
                    SelectorWindowHost.register(originWindow)
                    ownsOrigin = true
                }
                origin.reveal()
                anchorReady = true
            } else {
                anchorReady = false
                releaseOrigin()
                Task { @MainActor in
                    await Task.yield()
                    originWindow?.makeFirstResponder(nil)
                    onDismiss()
                }
            }
        }
        .onDisappear(perform: releaseOrigin)
    }

    private func releaseOrigin() {
        if ownsOrigin, let originWindow { SelectorWindowHost.unregister(originWindow) }
        ownsOrigin = false
    }

    private var control: some View {
        Button {
            originWindow = origin.window ?? NSApp.keyWindow
            presented.wrappedValue = true
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.title ?? "Choose…")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .accessibilityIdentifier(identifier)
        .accessibilityValue(options.first { $0.value == selection }?.title ?? "")
        .background(SelectorOriginView(origin: origin))
        .popover(isPresented: popoverPresented, arrowEdge: .bottom) {
            MacChoiceSelector(
                title: title, selection: $selection, options: options, identifier: identifier,
                preservesOrder: preservesOrder, create: create, close: { presented.wrappedValue = false })
        }
    }
}

private struct MacChoiceSelector<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [MacChoice<Value>]
    let identifier: String
    let preservesOrder: Bool
    let create: ((String) -> Value?)?
    let close: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @State private var error: String?

    private var matches: [Int] {
        SelectorSearch.rankedIndices(in: options.map(\.title), query: query, preservingOrder: preservesOrder)
    }
    private var newName: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { create != nil && !newName.isEmpty && matches.isEmpty }
    private var count: Int { matches.count + (canCreate ? 1 : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SelectorInput(text: $query, placeholder: "Find \(title.lowercased())…", identifier: "\(identifier)-search", command: command)
                .frame(height: 26)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element) { row, index in
                            Button { choose(row) } label: {
                                HStack {
                                    Text(options[index].title)
                                    Spacer()
                                    if options[index].value == selection { Image(systemName: "checkmark") }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .background(highlighted == row ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                .foregroundStyle(highlighted == row ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("\(identifier)-option-\(index)")
                            .accessibilityValue(highlighted == row ? "Highlighted" : "Not highlighted")
                            .accessibilityAddTraits(highlighted == row ? .isSelected : [])
                            .id(index)
                        }
                        if canCreate {
                            Button { choose(0) } label: {
                                Label("Create ‘\(newName)’", systemImage: "plus.circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("\(identifier)-create")
                        } else if matches.isEmpty {
                            Text("No matches").foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                .frame(maxHeight: 240)
                .onChange(of: highlighted) {
                    if matches.indices.contains(highlighted) { proxy.scrollTo(matches[highlighted]) }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("↑ ↓ / ⌃N ⌃P to move · ↩ to choose · esc to cancel")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 310)
        .background(SelectorWindowGuard())
        .onExitCommand(perform: close)
        .onAppear { highlighted = matches.firstIndex { options[$0].value == selection } ?? 0 }
        .onChange(of: query) { highlighted = 0; error = nil }
    }

    private func command(_ name: String) -> Bool {
        switch name {
        case "moveDown:": highlighted = count == 0 ? 0 : (highlighted + 1) % count
        case "moveUp:": highlighted = count == 0 ? 0 : (highlighted + count - 1) % count
        case "insertNewline:": choose(highlighted)
        case "cancelOperation:": close()
        default: return false
        }
        return true
    }

    private func choose(_ row: Int) {
        if canCreate, let create {
            guard let value = create(newName) else {
                error = "Could not create the category. Try again after syncing."
                return
            }
            selection = value
            close()
        } else if matches.indices.contains(row) {
            selection = options[matches[row]].value
            close()
        }
    }
}
