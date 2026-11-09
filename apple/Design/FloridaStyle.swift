import SwiftUI

/// App-only design resources. Neither portable Swift package depends on SwiftUI or these assets.
enum FloridaStyle {
    static let paper = Color("Paper")
    static let panel = Color("Panel")
    static let ink = Color("Ink")
    static let rule = Color("Rule")

    /// Deterministic native captures; normal launches and Release builds follow the device.
    static var captureColorScheme: ColorScheme? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "uiAppearance") {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

struct FloridaMark: View {
    var body: some View {
        Image("FloridaMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

/// Instrument Serif is outlined artwork, not an app font. UI text stays in the system font,
/// with native Dynamic Type, while the identity renders without font registration or I/O.
struct FloridaWordmark: View {
    var height: CGFloat = 28

    var body: some View {
        HStack(spacing: height * 0.38) {
            FloridaMark()
                .frame(width: height * 0.74, height: height * 0.74)
            Image("FloridaWordmark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: height * 3, height: height)
        }
        .foregroundStyle(FloridaStyle.ink)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Florida")
        .accessibilityAddTraits(.isImage)
    }
}
