import AppKit
import SwiftUI

/// The menu bar item: the mark, then "Standup in 12m · Mon Nov 9, 2026 2:03 PM". Always shows the
/// date and time.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Self.mark)
            Text(model.menuBarTitle)
                .monospacedDigit()
        }
    }

    /// A status item draws a label's image at the image's own size: SwiftUI's `resizable` and
    /// `frame` do nothing there, so the asset drew full size and the bar showed a clipped corner
    /// of it. The mark is sized here instead, as a template so it follows the menu bar's color.
    @MainActor private static let mark: NSImage = {
        let image = (NSImage(named: "FloridaMark")?.copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 14, height: 14)
        image.isTemplate = true
        return image
    }()
}
