import FloridaKit
import SwiftUI

struct LaterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var status: LaterItem.Status = .queue
    @State private var selectedID: String?
    @State private var deleting: LaterItem?
    @State private var error: String?

    private var items: [LaterItem] { model.later.items(in: status) }

    var body: some View {
        let selected = items.first { $0.id == selectedID }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Later", systemImage: "bookmark")
                    .font(.headline)
                Spacer()
                Picker("Later status", selection: $status) {
                    ForEach(LaterItem.Status.allCases, id: \.self) { value in
                        Text(value.laterDisplayTitle).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("later-status")
            }
            List(selection: $selectedID) {
                ForEach(items) { item in
                    LaterLinkRow(item: item)
                        .tag(item.id)
                }
            }
            .listStyle(.inset)
            .overlay {
                if items.isEmpty {
                    Text("No items here.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("later-empty")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text(model.later.archivedThisMonth(at: model.clockNow, calendar: model.calendar))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open") {
                    if let url = selected?.openURL { openURL(url) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected?.openURL == nil)
                Button("Mark read") {
                    if let selected {
                        error = model.writeLater { try $0.setLaterState(id: selected.id, action: .read) }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Mark the selected link read (⌘⇧R)")
                .accessibilityIdentifier("later-mark-read")
                .disabled(selected == nil || status == .read)
                Button("Archive") {
                    if let selected {
                        error = model.writeLater { try $0.setLaterState(id: selected.id, action: .archive) }
                    }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Archive the selected link (⌘⇧A)")
                .disabled(selected == nil || status == .archived)
                Button("Delete") { deleting = selected }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Delete the selected link (⌘⌫)")
                    .disabled(selected == nil)
                Button("Close") { model.isLaterOpen = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("later-close")
            }
        }
        .padding(16)
        .frame(width: 610, height: 380)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("later-sheet")
        .onChange(of: items.map(\.id), initial: true) { _, ids in
            if selectedID.map(ids.contains) != true { selectedID = ids.first }
        }
        .alert("Delete this link?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { item in
            Button("Delete", role: .destructive) {
                error = model.writeLater { try $0.deleteLater(id: item.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.title)
        }
    }
}

struct LaterLinkRow: View {
    @Environment(\.openURL) private var openURL
    let item: LaterItem

    var body: some View {
        let symbol = switch item.kind {
        case .article: "doc.text"
        case .video: "play.rectangle"
        case .other: "link"
        }
        Button {
            if let url = item.openURL { openURL(url) }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).lineLimit(1)
                    Text("\(item.site) · \(item.laterEstimateLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(item.kind.rawValue.capitalized)
            }
        }
        .buttonStyle(.borderless)
        .disabled(item.openURL == nil)
        .accessibilityLabel(item.title)
        .accessibilityValue("\(item.kind.rawValue.capitalized), \(item.site), \(item.laterEstimateLabel)")
        .accessibilityIdentifier("later-item-\(item.id)")
    }
}
