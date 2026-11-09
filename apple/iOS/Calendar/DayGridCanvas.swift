import FloridaKit
import SwiftUI

/// The grid's chrome in one `Canvas`: today's column tint, hour and half-hour lines, the gutter
/// labels, day separators and the now line. Blocks are views on top of it. Pure drawing from
/// precomputed labels and geometry; `now` comes from the enclosing `TimelineView`, once a minute.
struct DayGridCanvas: View {
    let geometry: DayGridGeometry
    let days: [Date]
    let hourLabels: [HourLabel]
    let now: Date
    let calendar: Calendar

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            drawTodayTint(in: &context)
            drawHourLines(in: &context, width: size.width)
            drawDaySeparators(in: &context)
            drawNowLine(in: &context)
        }
        .frame(width: geometry.width, height: geometry.dayHeight)
    }

    private var todayIndex: Int? {
        days.firstIndex { calendar.isDate($0, inSameDayAs: now) }
    }

    private func drawTodayTint(in context: inout GraphicsContext) {
        guard let todayIndex else { return }
        context.fill(Path(geometry.columnRect(forDay: todayIndex)), with: .color(FloridaStyle.ink.opacity(0.025)))
    }

    private func drawHourLines(in context: inout GraphicsContext, width: CGFloat) {
        let lineColor = FloridaStyle.rule
        let gutter = geometry.gutterWidth
        var hours = Path()
        var halves = Path()
        for label in hourLabels {
            let y = CGFloat(geometry.grid.y(forMinute: label.minute))
            hours.move(to: CGPoint(x: gutter, y: y))
            hours.addLine(to: CGPoint(x: width, y: y))
            let halfY = CGFloat(geometry.grid.y(forMinute: label.minute + 30))
            halves.move(to: CGPoint(x: gutter, y: halfY))
            halves.addLine(to: CGPoint(x: width, y: halfY))
            if label.minute > 0 {
                context.draw(
                    Text(label.label).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                    at: CGPoint(x: gutter - 6, y: y), anchor: .trailing)
            }
        }
        context.stroke(hours, with: .color(lineColor), lineWidth: 1)
        context.stroke(halves, with: .color(lineColor.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
    }

    private func drawDaySeparators(in context: inout GraphicsContext) {
        var lines = Path()
        for index in 0...max(days.count, 0) {
            let x = geometry.x(forDay: index)
            lines.move(to: CGPoint(x: x, y: 0))
            lines.addLine(to: CGPoint(x: x, y: geometry.dayHeight))
        }
        context.stroke(lines, with: .color(FloridaStyle.rule), lineWidth: 1)
    }

    private func drawNowLine(in context: inout GraphicsContext) {
        guard let todayIndex else { return }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let y = CGFloat(geometry.grid.y(forMinute: (components.hour ?? 0) * 60 + (components.minute ?? 0)))
        let column = geometry.columnRect(forDay: todayIndex)
        var line = Path()
        line.move(to: CGPoint(x: column.minX, y: y))
        line.addLine(to: CGPoint(x: column.maxX, y: y))
        context.stroke(line, with: .color(.red), lineWidth: 1.5)
        context.fill(Path(ellipseIn: CGRect(x: column.minX - 3.5, y: y - 3.5, width: 7, height: 7)), with: .color(.red))
    }
}
