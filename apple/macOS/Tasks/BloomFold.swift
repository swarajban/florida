import SwiftUI

/// The removal of a completed task row: its category color blooms over it while it folds up
/// and fades, all within the list's ~150 ms removal animation.
struct BloomFold: ViewModifier, Animatable {
    /// 0 while the row is shown, 1 once it is gone.
    var progress: Double
    let tint: Color

    /// Nonisolated: `Animatable` is, while the `ViewModifier` conformance makes the type
    /// main-actor isolated.
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // The tint peaks a third of the way in, then fades with the row.
        let bloom = progress < 0.33 ? progress / 0.33 : max(0, 1 - (progress - 0.33) / 0.67)
        content
            .overlay(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.45 * bloom)).padding(.horizontal, 6))
            .scaleEffect(x: 1, y: max(0.05, 1 - progress * 0.9), anchor: .top)
            .opacity(1 - progress * progress)
    }
}

extension AnyTransition {
    static func bloomFold(_ tint: Color) -> AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .modifier(active: BloomFold(progress: 1, tint: tint), identity: BloomFold(progress: 0, tint: tint)))
    }
}
