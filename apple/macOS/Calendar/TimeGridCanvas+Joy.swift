import FloridaKit
import SwiftUI

// The time grid's optional touches, each switched by a Feel preference: off-hours shading,
// free gaps, the current block's progress, and blocks sliding to new slots.

extension TimeGridCanvas {
    /// Faintly shades each day's minutes outside every schedule window.
    func drawOffHours(in context: inout GraphicsContext, geometry: GridGeometry) {
        guard layout.options.dimsOffHours, layout.hasSchedules else { return }
        let shade = GraphicsContext.Shading.color(Color.primary.opacity(0.045))
        let end = DayLayout.minutesPerDay
        for (index, working) in layout.workingByDay.enumerated() {
            let column = geometry.columnRect(forDay: index)
            var cursor = 0
            for range in working + [end..<end] {
                if range.lowerBound > cursor {
                    let top = grid.y(forMinute: cursor)
                    let rect = CGRect(x: column.minX, y: top, width: column.width, height: grid.y(forMinute: range.lowerBound) - top)
                    context.fill(Path(rect), with: shade)
                }
                cursor = max(cursor, range.upperBound)
            }
        }
    }

    /// A dashed outline and "42 min free" in each free stretch of schedule time.
    func drawGaps(in context: inout GraphicsContext, geometry: GridGeometry) {
        for gaps in layout.gapsByDay {
            for gap in gaps {
                let rect = geometry.rect(for: gap)
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 4), with: .color(Color.secondary.opacity(0.3)),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                guard rect.height >= 16 else { continue }
                context.draw(
                    Text(Self.freeText(minutes: gap.minutes)).font(.system(size: 10)).foregroundStyle(.tertiary),
                    at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
    }

    /// The block's frame at `frameDate`: eased from its old slot while `transition` runs. The
    /// block being dragged is where the drag has it, the full width of its day.
    func animatedRect(for block: GridLayout.Block, geometry: GridGeometry) -> CGRect {
        if let drag, drag.applies(to: block) {
            return geometry.rect(
                dayIndex: drag.dayIndex, column: 0, columnCount: 1, startMinute: drag.startMinute, endMinute: drag.endMinute)
        }
        let target = geometry.rect(for: block)
        guard let transition, block.isTask, let slot = transition.from[block.slotKey] else { return target }
        let elapsed = frameDate.timeIntervalSince(transition.startedAt) / LayoutTransition.duration
        let t = min(1, max(0, elapsed))
        guard t < 1 else { return target }
        let eased = 1 - pow(1 - t, 3)
        let from = geometry.rect(for: slot)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(eased) }
        return CGRect(
            x: mix(from.minX, target.minX), y: mix(from.minY, target.minY),
            width: mix(from.width, target.width), height: mix(from.height, target.height))
    }

    /// Fills the block from the left up to how much of it has passed.
    func drawProgressFill(of block: GridLayout.Block, in context: inout GraphicsContext, rect: CGRect) {
        let total = block.end.timeIntervalSince(block.start)
        guard total > 0 else { return }
        let fraction = min(1, max(0, now.timeIntervalSince(block.start) / total))
        var filled = rect
        filled.size.width = rect.width * CGFloat(fraction)
        let color = block.tint.opacity(0.12)
        context.fill(Path(filled), with: .color(color))
    }

    /// "23 min left" in the block's bottom-right corner, when it is tall enough.
    func drawTimeLeft(of block: GridLayout.Block, in context: inout GraphicsContext, rect: CGRect, color: Color) {
        guard rect.height >= 30 else { return }
        let minutes = max(1, Int((block.end.timeIntervalSince(now) / 60).rounded(.up)))
        context.draw(
            Text(Self.leftText(minutes: minutes)).font(.system(size: 9, weight: .semibold)).foregroundStyle(color.opacity(0.85)),
            at: CGPoint(x: rect.maxX - 4, y: rect.maxY - 3), anchor: .bottomTrailing)
    }

    /// "42 min free", "2h 10m free".
    static func freeText(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min free" : "\(DateText.duration(minutes: minutes)) free"
    }

    /// "23 min left", "1h 5m left".
    static func leftText(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min left" : "\(DateText.duration(minutes: minutes)) left"
    }
}
