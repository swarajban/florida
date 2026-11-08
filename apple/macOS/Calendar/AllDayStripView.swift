import FloridaKit
import SwiftUI

/// All-day events as bars spanning their day columns, one row per `AllDayLayout` row. Hidden
/// when the visible days have none.
struct AllDayStripView: View {
    @Environment(AppModel.self) private var model
    let gutterWidth: CGFloat

    static let rowHeight: CGFloat = 22

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
                        let isSelected = model.selection == block.item
                        Text(block.title)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(
                                width: max(CGFloat(block.endDayIndex - block.startDayIndex + 1) * columnWidth - 4, 4),
                                height: Self.rowHeight - 4,
                                alignment: .leading)
                            .background(block.tint.opacity(block.start < Date() ? 0.6 : 0.9), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary, lineWidth: isSelected ? 2 : 0))
                            .offset(
                                x: gutterWidth + CGFloat(block.startDayIndex) * columnWidth + 2,
                                y: CGFloat(block.row) * Self.rowHeight + 2)
                            .onTapGesture(count: 2) {
                                model.select(block.item, in: .calendar)
                                model.editSelection()
                            }
                            .onTapGesture {
                                model.select(block.item, in: .calendar)
                            }
                    }
                }
            }
            .frame(height: CGFloat(layout.allDayRowCount) * Self.rowHeight + 2)
            Divider()
        }
    }
}
