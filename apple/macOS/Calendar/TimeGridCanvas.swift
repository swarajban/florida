import FloridaKit
import SwiftUI

/// Draws one `GridLayout` into a `Canvas`: hour lines and labels, day separators, the day
/// tints, every block, the focus ring and the "now" line. Pure drawing from precomputed frames;
/// `TimelineView` redraws it once a minute for the now line and past-dimming.
struct TimeGridCanvas: View {
    let layout: GridLayout
    let selection: ItemID?
    let selectedDay: Date
    let now: Date
    let calendar: Calendar
    let grid: TimeGrid
    let gutterWidth: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let geometry = GridGeometry(size: size, gutterWidth: gutterWidth, dayCount: layout.days.count, grid: grid)
            drawDayTints(in: &context, geometry: geometry)
            drawHourLines(in: &context, geometry: geometry)
            drawDaySeparators(in: &context, geometry: geometry)
            for blocks in layout.blocksByDay {
                for block in blocks {
                    draw(block, in: &context, geometry: geometry)
                }
            }
            drawSelectionRing(in: &context, geometry: geometry)
            drawNowLine(in: &context, geometry: geometry)
        }
        .frame(height: grid.dayHeight)
    }

    // MARK: Chrome

    private func drawDayTints(in context: inout GraphicsContext, geometry: GridGeometry) {
        for (index, day) in layout.days.enumerated() {
            let rect = geometry.columnRect(forDay: index)
            if calendar.isDate(day, inSameDayAs: now) {
                context.fill(Path(rect), with: .color(Color.accentColor.opacity(0.05)))
            } else if calendar.isDate(day, inSameDayAs: selectedDay) {
                context.fill(Path(rect), with: .color(Color.primary.opacity(0.03)))
            }
        }
    }

    private func drawHourLines(in context: inout GraphicsContext, geometry: GridGeometry) {
        let lineColor = Color(nsColor: .separatorColor)
        for (minute, label) in TimeGrid.hourLabels() {
            let y = grid.y(forMinute: minute)
            var line = Path()
            line.move(to: CGPoint(x: gutterWidth, y: y))
            line.addLine(to: CGPoint(x: geometry.size.width, y: y))
            context.stroke(line, with: .color(lineColor), lineWidth: 1)

            var half = Path()
            let halfY = grid.y(forMinute: minute + 30)
            half.move(to: CGPoint(x: gutterWidth, y: halfY))
            half.addLine(to: CGPoint(x: geometry.size.width, y: halfY))
            context.stroke(half, with: .color(lineColor.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            if minute > 0 {
                context.draw(
                    Text(label).font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: gutterWidth - 6, y: y), anchor: .trailing)
            }
        }
    }

    private func drawDaySeparators(in context: inout GraphicsContext, geometry: GridGeometry) {
        let lineColor = Color(nsColor: .separatorColor)
        for index in 0...max(layout.days.count, 0) {
            let x = geometry.x(forDay: index)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: grid.dayHeight))
            context.stroke(line, with: .color(lineColor), lineWidth: 1)
        }
    }

    private func drawNowLine(in context: inout GraphicsContext, geometry: GridGeometry) {
        guard let todayIndex = layout.days.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) }) else { return }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let y = grid.y(forMinute: (components.hour ?? 0) * 60 + (components.minute ?? 0))
        let column = geometry.columnRect(forDay: todayIndex)
        var line = Path()
        line.move(to: CGPoint(x: column.minX, y: y))
        line.addLine(to: CGPoint(x: column.maxX, y: y))
        context.stroke(line, with: .color(.red), lineWidth: 1.5)
        context.fill(Path(ellipseIn: CGRect(x: column.minX - 3.5, y: y - 3.5, width: 7, height: 7)), with: .color(.red))
    }

    // MARK: Blocks

    private func draw(_ block: GridLayout.Block, in context: inout GraphicsContext, geometry: GridGeometry) {
        let rect = geometry.rect(for: block)
        let shape = Path(roundedRect: rect, cornerRadius: 4)
        let alpha: Double = block.end < now ? 0.45 : 1
        let textColor: Color
        switch block.kind {
        case .event:
            context.fill(shape, with: .color(block.tint.opacity(0.85 * alpha)))
            textColor = .white.opacity(alpha)
        case .task(let pinned):
            context.fill(shape, with: .color(block.tint.opacity(0.16 * alpha)))
            context.stroke(
                shape, with: .color(block.tint.opacity(alpha)),
                style: StrokeStyle(lineWidth: 1, dash: pinned ? [] : [3, 2]))
            textColor = block.tint.opacity(alpha)
        }

        var inner = context
        inner.clip(to: shape)
        let padding: CGFloat = 4
        var titleRect = rect.insetBy(dx: padding, dy: 2)
        if block.isPinned {
            let pinSize: CGFloat = 10
            inner.draw(
                Text(Image(systemName: "pin.fill")).font(.system(size: 9)).foregroundStyle(textColor),
                at: CGPoint(x: rect.maxX - padding - pinSize / 2, y: rect.minY + 2 + pinSize / 2))
            titleRect.size.width -= pinSize + 2
        }
        let title = Text(block.title).font(.system(size: 11, weight: .medium)).foregroundStyle(textColor)
        if rect.height >= 34 {
            inner.draw(title, in: CGRect(x: titleRect.minX, y: titleRect.minY, width: titleRect.width, height: 14))
            inner.draw(
                Text(DateText.timeRange(block.start, block.end)).font(.system(size: 10)).foregroundStyle(textColor.opacity(0.85)),
                in: CGRect(x: titleRect.minX, y: titleRect.minY + 14, width: titleRect.width, height: 13))
        } else {
            inner.draw(title, in: CGRect(x: titleRect.minX, y: rect.minY + 1, width: titleRect.width, height: max(rect.height - 2, 8)))
        }
    }

    private func drawSelectionRing(in context: inout GraphicsContext, geometry: GridGeometry) {
        guard let selection else { return }
        for blocks in layout.blocksByDay {
            for block in blocks where block.item == selection {
                let ring = Path(roundedRect: geometry.rect(for: block).insetBy(dx: -1.5, dy: -1.5), cornerRadius: 5.5)
                context.stroke(ring, with: .color(Color.accentColor), lineWidth: 2)
            }
        }
    }
}
