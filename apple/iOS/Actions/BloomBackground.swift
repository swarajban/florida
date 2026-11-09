import SwiftUI

/// A list row background that floods with `color` when `active` turns on (the ~150 ms bloom of a
/// task just completed), over the grouped cell background and an optional `tint`.
struct BloomBackground: View {
    let color: Color
    let active: Bool
    var tint: Color? = nil
    var base: Color = FloridaStyle.paper
    @State private var shown = false

    var body: some View {
        ZStack {
            base
            if let tint {
                tint
            }
            color.opacity(shown ? 0.35 : 0)
        }
        .onChange(of: active, initial: true) { _, active in
            withAnimation(.easeOut(duration: 0.12)) {
                shown = active
            }
        }
    }
}
