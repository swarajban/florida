import SwiftUI

/// The menu bar item: "Mon Nov 9, 2026 · Standup in 12m". Always shows the date.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            FloridaMark()
                .frame(width: 12, height: 12)
            Text(model.menuBarTitle)
                .monospacedDigit()
        }
    }
}
