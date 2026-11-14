import SwiftUI

/// The key that reaches a control, shown beside it: a quiet outlined tag, so a form full of them
/// still reads as a form. It takes the colour of the text around it, so it also reads on a filled
/// button. Hidden from accessibility: the control keeps its own name.
struct Keycap: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            // One line whatever the control: a multi-line field's label inherits the field's line
            // range, and only another range replaces its lower bound.
            .lineLimit(1...1)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 15)
            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(.tertiary, lineWidth: 1))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A control's name with its key after it.
struct KeyLabel: View {
    let title: String
    let key: String

    init(_ title: String, key: String) {
        self.title = title
        self.key = key
    }

    var body: some View {
        // By baseline, not centre: a multi-line field's title is as tall as the field.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
            Keycap(key)
        }
    }
}
