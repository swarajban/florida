import FloridaKit
import SafariServices
import SwiftUI

struct LaterView: View {
    @Environment(AppModel.self) private var model
    @State private var status: LaterItem.Status = .queue
    @State private var visit = LaterVisit()
    @State private var browser: BrowserLink?
    @State private var finishedItem: LaterItem?
    @State private var deletingItem: LaterItem?
    var block: CatchUpBlock? = nil

    private var items: [LaterItem] {
        if let block { return model.later.items(in: block) }
        return model.later.items(in: status)
    }

    var body: some View {
        List {
            if block == nil {
                Picker("Later status", selection: $status) {
                    ForEach(LaterItem.Status.allCases, id: \.self) {
                        Text($0.laterDisplayTitle).tag($0)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                if items.isEmpty {
                    Text(block == nil ? "No items here." : "No unread links in this block.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    if block == nil {
                        row(item)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if item.status != .read {
                                    Button { update(item, .read) } label: { Label("Mark read", systemImage: "checkmark") }
                                        .tint(.green)
                                }
                            }
                            .swipeActions(allowsFullSwipe: false) {
                                Button(role: .destructive) { deletingItem = item } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                if item.status != .archived {
                                    Button { update(item, .archive) } label: { Label("Archive", systemImage: "archivebox") }
                                        .tint(.indigo)
                                }
                            }
                    } else {
                        HStack {
                            row(item)
                            Button { update(item, .read) } label: { Image(systemName: "checkmark.circle") }
                                .buttonStyle(.borderless)
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityLabel("Mark \(item.title) read")
                        }
                    }
                }
            } footer: {
                if block == nil {
                    Text(model.later.archivedThisMonth(at: model.now, calendar: model.calendar))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(FloridaStyle.paper)
        .navigationTitle(block == nil ? "Later" : "Catch up")
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay()
        .fullScreenCover(item: $browser, onDismiss: {
            finishedItem = visit.finish(in: model.later)
        }) { link in
            LaterBrowser(link: link) { browser = nil }
                .ignoresSafeArea()
        }
        .alert("Finished?", isPresented: Binding(
            get: { finishedItem != nil }, set: { if !$0 { finishedItem = nil } }
        ), presenting: finishedItem) { item in
            Button("Mark read") { update(item, .read) }
            Button("Keep", role: .cancel) {}
        } message: { item in
            Text(item.title)
        }
        .alert("Delete this link?", isPresented: Binding(
            get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } }
        ), presenting: deletingItem) { item in
            Button("Delete", role: .destructive) { model.write { try $0.deleteLater(id: item.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.title)
        }
    }

    private func row(_ item: LaterItem) -> some View {
        Button {
            guard let url = item.openURL else { return }
            visit.open(item)
            browser = BrowserLink(url: url, readerMode: item.kind == .article)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).foregroundStyle(.primary)
                    Text("\(item.site) · \(item.laterEstimateLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: switch item.kind {
                case .article: "doc.text"
                case .video: "play.rectangle"
                case .other: "link"
                })
                .foregroundStyle(.secondary)
                .accessibilityLabel(item.kind.rawValue.capitalized)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(item.openURL == nil)
        .accessibilityIdentifier("later-item-\(item.id)")
    }

    private func update(_ item: LaterItem, _ action: LaterItem.Action) {
        model.write { try $0.setLaterState(id: item.id, action: action) }
    }
}

private struct BrowserLink: Identifiable {
    let url: URL
    let readerMode: Bool
    var id: URL { url }
}

private struct LaterBrowser: UIViewControllerRepresentable {
    let link: BrowserLink
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = link.readerMode
        let controller = SFSafariViewController(url: link.url, configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let dismiss: () -> Void

        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { dismiss() }
    }
}
