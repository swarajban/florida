import FloridaKit
import SwiftUI

/// All-day events as bars spanning their day columns, one row per `AllDayLayout` row. Hidden
/// when the visible days have none.
struct AllDayStripView: View {
    @Environment(AppModel.self) private var model
    let gutterWidth: CGFloat

    static let rowHeight: CGFloat = 22

    /// The all-day bar of the open event detail, if it is an all-day event.
    private var detailBlock: GridLayout.AllDayBlock? {
        guard let id = model.eventDetailID else { return nil }
        return model.gridLayout.allDayBlocks.first { $0.item == .event(id) }
    }

    var body: some View {
        let layout = model.gridLayout
        if layout.allDayRowCount > 0 {
            GeometryReader { proxy in
                let dayCount = max(layout.days.count, 1)
                let columnWidth = max(0, proxy.size.width - gutterWidth) / CGFloat(dayCount)
                ZStack(alignment: .topLeading) {
                    Text("all-day")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: gutterWidth - 8, height: Self.rowHeight, alignment: .trailing)
                    ForEach(layout.allDayBlocks) { block in
                        AllDayBar(
                            block: block,
                            columnWidth: columnWidth,
                            gutterWidth: gutterWidth,
                            isSelected: model.selection == block.item,
                            isPast: block.localEnd <= model.clockNow,
                            jumpLabel: model.jumpLabel(for: block.item))
                            .onClick { isDouble in
                                if model.jumpLabel(for: block.item) != nil {
                                    model.selectJumped(block.item)
                                } else {
                                    model.select(block.item, in: .calendar)
                                    if isDouble { model.editSelection() }
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .eventDetailPopover(
                    model, eventId: detailBlock?.id,
                    anchor: .rect(.rect(detailBlock.map {
                        AllDayBar.frame(for: $0, columnWidth: columnWidth, gutterWidth: gutterWidth)
                    } ?? .zero)))
            }
            .frame(height: CGFloat(layout.allDayRowCount) * Self.rowHeight + 2)
            Divider()
        }
    }
}

/// One all-day bar. Its geometry is computed up front in plain `let`s: the same chain inlined in
/// the `ForEach` closure made the type checker give up ("unable to type-check this expression in
/// reasonable time").
private struct AllDayBar: View {
    let block: GridLayout.AllDayBlock
    let columnWidth: CGFloat
    let gutterWidth: CGFloat
    let isSelected: Bool
    /// The event's last local day has ended (its stored UTC start would dim it a day early).
    let isPast: Bool
    /// Jump mode's label for this event, shown before its title.
    let jumpLabel: String?

    /// Where the bar is drawn in the strip; also the detail popover's anchor.
    static func frame(for block: GridLayout.AllDayBlock, columnWidth: CGFloat, gutterWidth: CGFloat) -> CGRect {
        let spannedDays = CGFloat(block.endDayIndex - block.startDayIndex + 1)
        let width: CGFloat = max(spannedDays * columnWidth - 4, 4)
        let height: CGFloat = AllDayStripView.rowHeight - 4
        let x: CGFloat = gutterWidth + CGFloat(block.startDayIndex) * columnWidth + 2
        let y: CGFloat = CGFloat(block.row) * AllDayStripView.rowHeight + 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    var body: some View {
        let frame = Self.frame(for: block, columnWidth: columnWidth, gutterWidth: gutterWidth)
        let opacity: Double = isPast ? 0.6 : 1
        let shape = RoundedRectangle(cornerRadius: 4)

        HStack(spacing: 4) {
            if let jumpLabel {
                JumpBadge(label: jumpLabel)
                    .accessibilityIdentifier("event-jump-\(block.id)")
                    .accessibilityValue(jumpLabel.uppercased())
            }
            Text(block.title)
                .font(.caption)
                .foregroundStyle(FloridaStyle.ink.opacity(opacity))
                .lineLimit(1)
        }
        .padding(.leading, jumpLabel == nil ? 6 : 2)
        .padding(.trailing, 6)
        .frame(width: frame.width, height: frame.height, alignment: .leading)
        .background(block.tint.opacity(0.12 * opacity), in: shape)
        .overlay(shape.strokeBorder(block.tint.opacity(0.4 * opacity), lineWidth: 1))
        .overlay(shape.strokeBorder(FloridaStyle.ink, lineWidth: isSelected ? 2 : 0))
        .offset(x: frame.minX, y: frame.minY)
    }
}
