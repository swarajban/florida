import FloridaKit
import SwiftUI

private struct CatchUpPopover: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    let block: CatchUpBlock

    var body: some View {
        let items = model.later.items(in: block)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(block.laterDisplayTitle, systemImage: "bookmark")
                    .font(.headline)
                Spacer()
                Text(DateText.timeRange(block.startAt, block.endAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text("No unread links in this block.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("catch-up-empty")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            HStack {
                                LaterLinkRow(item: item)
                                Spacer(minLength: 8)
                                Button {
                                    error = model.writeLater { try $0.setLaterState(id: item.id, action: .read) }
                                } label: {
                                    Image(systemName: "checkmark.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Mark read")
                                .accessibilityLabel("Mark \(item.title) read")
                                .accessibilityIdentifier("catch-up-mark-read-\(item.id)")
                            }
                            .frame(height: 40)
                        }
                    }
                }
                .frame(height: min(CGFloat(items.count) * 40, 200))
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 310, alignment: .leading)
    }
}

extension View {
    func catchUpBlockAccessibility(itemCount: Int) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityLabel(itemCount == 1 ? "Catch up, 1 item" : "Catch up, \(itemCount) items")
            .accessibilityIdentifier("catch-up-block")
            .accessibilityAddTraits(.isButton)
    }

    func catchUpPopover(
        _ model: AppModel, id: String?, anchor: PopoverAttachmentAnchor = .rect(.bounds)
    ) -> some View {
        let presented = Binding(
            get: { id != nil && model.catchUpDetailID == id },
            set: { if !$0, model.catchUpDetailID == id { model.catchUpDetailID = nil } })
        return popover(isPresented: presented, attachmentAnchor: anchor, arrowEdge: .trailing) {
            if let block = model.planSummary.catchUpBlocks.first(where: { $0.id == id }) {
                CatchUpPopover(block: block)
                    .environment(model)
            }
        }
    }
}
