import SwiftUI

/// The ghost label: a small capsule near the bottom of the window confirming the last action
/// ("Pinned to Tue 2:00 PM"). It never takes clicks, so it cannot get in the way.
struct GhostView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let ghost = model.ghost {
                Text(ghost.text)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .id(ghost.id)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.ghost)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}
