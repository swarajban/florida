import FloridaKit
import SwiftUI

/// A category's color dot; clicking it opens the palette swatches and a custom color well.
struct CategoryColorButton: View {
    let hex: String?
    let onPick: (String) -> Void
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            Circle()
                .fill(hex.flatMap(Color.init(hex:)) ?? .defaultCategory)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help("Color")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: 5), spacing: 8) {
                    ForEach(AppModel.categoryPalette, id: \.self) { swatch in
                        Button {
                            onPick(swatch)
                            isOpen = false
                        } label: {
                            Circle()
                                .fill(Color(hex: swatch) ?? .defaultCategory)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(Color.primary, lineWidth: swatch == hex ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
                ColorPicker("Custom…", selection: customColor, supportsOpacity: false)
            }
            .padding(12)
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { hex.flatMap(Color.init(hex:)) ?? .defaultCategory },
            set: { color in
                if let picked = color.hexString { onPick(picked) }
            })
    }
}
