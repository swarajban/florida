import FloridaKit
import SwiftUI

/// Draws one `GridLayout` into a `Canvas`: off-hours shading, hour lines and labels, day
/// separators, the day tints, free gaps, every block (sliding from its old slot while
/// `transition` runs, the current one filling as it goes; a suggestion dotted, barely filled,
/// with a moon; the gym solid and neutral; project time in long dashes), the focus ring and the
/// "now" line. A block that shares its hour with other parallel work is marked, and says what
/// runs beside it when it is tall enough. In jump mode each labelled block carries its label on
/// its top-left corner, and its title starts after it; a block cut off by the top of the scrolled
/// grid carries it where the block comes into view.
/// Pure drawing from precomputed frames and labels; `now` is the model's minute clock.
struct TimeGridCanvas: View {
    let layout: GridLayout
    let selection: ItemID?
    /// Jump mode's labels, by item; empty when the mode is off.
    let jumpLabels: [ItemID: String]
    /// The stretch of the grid that was on screen when the labels went up; nil when the mode is off.
    let jumpViewport: JumpViewport?
    let selectedDay: Date
    let now: Date
    /// The animation frame's time, which drives `transition`.
    let frameDate: Date
    let transition: LayoutTransition?
    let showsProgress: Bool
    let calendar: Calendar
    /// `AppModel.hourLabels`: formatted once, not per frame.
    let hourLabels: [(minute: Int, label: String)]
    let grid: TimeGrid
    let gutterWidth: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let geometry = GridGeometry(size: size, gutterWidth: gutterWidth, dayCount: layout.days.count, grid: grid)
            drawDayTints(in: &context, geometry: geometry)
            drawOffHours(in: &context, geometry: geometry)
            drawHourLines(in: &context, geometry: geometry)
            drawDaySeparators(in: &context, geometry: geometry)
            drawGaps(in: &context, geometry: geometry)
            for blocks in layout.blocksByDay {
                for block in blocks {
                    draw(block, in: &context, geometry: geometry)
                }
            }
            drawSelectionRing(in: &context, geometry: geometry)
            drawNowLine(in: &context, geometry: geometry)
            drawJumpLabels(in: &context, geometry: geometry)
        }
        .frame(height: grid.dayHeight)
        .accessibilityChildren {
            ForEach(layout.blocksByDay.flatMap { $0 }.filter { $0.kind == .completed }) { block in
                Text("Completed: \(block.title)")
                    .accessibilityValue("Done at \(DateText.time(block.start))")
            }
        }
    }

    // MARK: Chrome

    private func drawDayTints(in context: inout GraphicsContext, geometry: GridGeometry) {
        for (index, day) in layout.days.enumerated() {
            let rect = geometry.columnRect(forDay: index)
            if calendar.isDate(day, inSameDayAs: now) {
                context.fill(Path(rect), with: .color(FloridaStyle.ink.opacity(0.025)))
            } else if calendar.isDate(day, inSameDayAs: selectedDay) {
                context.fill(Path(rect), with: .color(Color.primary.opacity(0.03)))
            }
        }
    }

    private func drawHourLines(in context: inout GraphicsContext, geometry: GridGeometry) {
        let lineColor = FloridaStyle.rule
        for (minute, label) in hourLabels {
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
        let lineColor = FloridaStyle.rule
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
        let rect = animatedRect(for: block, geometry: geometry)
        let shape = Path(roundedRect: rect, cornerRadius: 5)
        let alpha: Double = block.end < now || block.isSuggestion ? 0.6 : 1
        // Arbitrary calendar colors (including yellow) are not safe text colors in both themes.
        // Keep their identity in the fill/rim; ink stays readable on every subtle fill.
        let textColor = FloridaStyle.ink.opacity(alpha)
        switch block.kind {
        case .event:
            context.fill(shape, with: .color(block.tint.opacity(0.12 * alpha)))
            context.stroke(shape, with: .color(block.tint.opacity(0.5 * alpha)), lineWidth: 1)
            if let rim = block.rim {
                let accountEdge = CGRect(x: rect.minX, y: rect.minY + 3, width: 2, height: max(0, rect.height - 6))
                context.fill(Path(roundedRect: accountEdge, cornerRadius: 1), with: .color(rim.opacity(alpha)))
            }
        case .completed:
            context.fill(shape, with: .color(block.tint.opacity(0.05)))
            context.stroke(shape, with: .color(block.tint.opacity(0.3)), lineWidth: 1)
        case .task(let pinned):
            context.fill(shape, with: .color(block.tint.opacity(0.04 * alpha)))
            context.stroke(
                shape, with: .color(block.tint.opacity(0.6 * alpha)),
                style: StrokeStyle(lineWidth: 1, dash: pinned ? [] : [3, 2]))
        case .suggestion:
            context.fill(shape, with: .color(block.tint.opacity(0.03)))
            context.stroke(shape, with: .color(block.tint.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        case .commitment:
            context.fill(shape, with: .color(block.tint.opacity(0.07 * alpha)))
            context.stroke(shape, with: .color(block.tint.opacity(0.45 * alpha)), lineWidth: 1)
        case .projectTime:
            context.fill(shape, with: .color(block.tint.opacity(0.04 * alpha)))
            context.stroke(
                shape, with: .color(block.tint.opacity(0.6 * alpha)), style: StrokeStyle(lineWidth: 1, dash: [7, 3]))
        }

        var inner = context
        inner.clip(to: shape)
        let isCurrent = showsProgress && !block.isSuggestion && block.kind != .completed && block.start <= now && now < block.end
        if isCurrent {
            drawProgressFill(of: block, in: &inner, rect: rect)
        }
        let padding: CGFloat = 4
        var titleRect = rect.insetBy(dx: padding, dy: 2)
        if let glyph = Self.glyph(for: block) {
            let pinSize: CGFloat = 10
            inner.draw(
                Text(Image(systemName: glyph)).font(.system(size: 9)).foregroundStyle(textColor),
                at: CGPoint(x: rect.maxX - padding - pinSize / 2, y: rect.minY + 2 + pinSize / 2))
            titleRect.size.width -= pinSize + 2
        }
        let title = Text(block.title).font(.system(size: 11, weight: .medium))
            .strikethrough(block.kind == .completed).foregroundStyle(textColor)
        var titleLine = titleRect
        if let badge = jumpBadge(for: block, in: rect), badge.frame.minY < titleLine.minY + 14 {
            // The label sits on the block's corner (`drawJumpLabels`), so the title starts after it.
            let inset = badge.frame.width + 1
            titleLine.origin.x += inset
            titleLine.size.width = max(titleLine.size.width - inset, 0)
        }
        // Empty when the block is too narrow for a title beside its label.
        let showsTitle = !titleLine.isEmpty
        if rect.height >= 34 {
            if showsTitle {
                inner.draw(title, in: CGRect(x: titleLine.minX, y: titleLine.minY, width: titleLine.width, height: 14))
            }
            inner.draw(
                Text(DateText.timeRange(block.start, block.end)).font(.system(size: 10)).foregroundStyle(textColor.opacity(0.85)),
                in: CGRect(x: titleRect.minX, y: titleRect.minY + 14, width: titleRect.width, height: 13))
            // From an hour up: shorter, and the line would sit under "23 min left".
            if rect.height >= 56, let note = Self.note(for: block) {
                inner.draw(
                    Text(note).font(.system(size: 10)).foregroundStyle(textColor.opacity(0.7)),
                    in: CGRect(x: rect.minX + padding, y: titleRect.minY + 27, width: rect.width - padding * 2, height: 13))
            }
        } else if showsTitle {
            inner.draw(title, in: CGRect(x: titleLine.minX, y: rect.minY + 1, width: titleLine.width, height: max(rect.height - 2, 8)))
        }
        if isCurrent {
            drawTimeLeft(of: block, in: &inner, rect: rect, color: textColor)
        }
    }

    /// The corner mark: pinned, suggested, the gym, project time, or sharing its hour.
    private static func glyph(for block: GridLayout.Block) -> String? {
        switch block.kind {
        case .completed: "checkmark.circle.fill"
        case .task(pinned: true): "pin.fill"
        case .suggestion: "moon.stars"
        case .commitment: PlanText.commitmentSymbol
        case .projectTime: PlanText.projectSymbol
        case .event, .task: block.companions.isEmpty ? nil : PlanText.parallelSymbol
        }
    }

    /// The third line of a tall block: what runs beside it, or that it is time held for a project.
    private static func note(for block: GridLayout.Block) -> String? {
        if let alongside = block.alongside { return alongside }
        return block.kind == .projectTime ? PlanText.projectTime : nil
    }

    /// Jump mode: every labelled block's label on its top-left corner, drawn last so that no
    /// neighboring block, ring or line covers one.
    private func drawJumpLabels(in context: inout GraphicsContext, geometry: GridGeometry) {
        guard !jumpLabels.isEmpty else { return }
        for blocks in layout.blocksByDay {
            for block in blocks {
                guard let badge = jumpBadge(for: block, in: animatedRect(for: block, geometry: geometry)) else { continue }
                context.fill(Path(roundedRect: badge.frame, cornerRadius: JumpBadge.cornerRadius), with: .color(FloridaStyle.ink))
                context.draw(JumpBadge.text(badge.label), at: CGPoint(x: badge.frame.midX, y: badge.frame.midY))
            }
        }
    }

    /// Jump mode's label for `block`, drawn in `rect`, and where it goes. Nil outside the mode,
    /// for a block without a label, and for one that was scrolled out of view when the labels
    /// went up: of a task's several blocks, only the ones on screen carry its label.
    private func jumpBadge(for block: GridLayout.Block, in rect: CGRect) -> (label: String, frame: CGRect)? {
        guard let label = jumpLabels[block.item],
              let top = JumpBadge.top(onBlockFrom: rect.minY, to: rect.maxY, in: jumpViewport)
        else { return nil }
        return (label, CGRect(x: rect.minX + 2, y: top, width: JumpBadge.width(for: label), height: JumpBadge.height))
    }

    private func drawSelectionRing(in context: inout GraphicsContext, geometry: GridGeometry) {
        guard let selection else { return }
        if case .gap(let id) = selection, let gap = layout.gap(id: id) {
            let ring = Path(roundedRect: geometry.rect(for: gap).insetBy(dx: -1.5, dy: -1.5), cornerRadius: 5.5)
            context.stroke(ring, with: .color(FloridaStyle.ink), lineWidth: 2)
            return
        }
        for blocks in layout.blocksByDay {
            for block in blocks where block.item == selection {
                let ring = Path(roundedRect: animatedRect(for: block, geometry: geometry).insetBy(dx: -1.5, dy: -1.5), cornerRadius: 5.5)
                context.stroke(ring, with: .color(FloridaStyle.ink), lineWidth: 2)
            }
        }
    }
}
