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
