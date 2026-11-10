import FloridaKit
import SwiftUI

/// A jump-mode label: a small ink tag on an item's leading edge, naming the keys that select it.
/// The time grid's canvas draws the same tag from these metrics.
struct JumpBadge: View {
    let label: String

    static let height: CGFloat = 13
    static let cornerRadius: CGFloat = 3

    /// The label's font is monospaced, so the width follows from the number of keys.
    static func width(for label: String) -> CGFloat {
        CGFloat(label.count) * 6.2 + 9
    }

    /// Where the label's top goes on a time-grid block whose frame runs from `top` to `bottom`:
    /// a point inside its top edge, or inside the top of `viewport` when that edge is scrolled
    /// off. Nil when too little of the block is on screen to hold a label. Without a viewport
    /// (the month view does not scroll) every block is on screen.
    static func top(onBlockFrom top: CGFloat, to bottom: CGFloat, in viewport: JumpViewport?) -> CGFloat? {
        guard let viewport else { return top + 1 }
        return viewport.labelTop(onItemFrom: top, to: bottom, labelHeight: height + 1).map { CGFloat($0) + 1 }
    }

    /// Capitals read better at this size; the keys are typed without Shift.
    static func text(_ label: String) -> Text {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(FloridaStyle.paper)
    }

    var body: some View {
        Self.text(label)
            .frame(width: Self.width(for: label), height: Self.height)
            .background(FloridaStyle.ink, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
    }
}
