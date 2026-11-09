import FloridaKit
import SwiftUI

/// The `?` overlay: every command grouped by section with its shortcuts. Escape, `?`, or a click
/// outside closes it.
struct HelpOverlayView: View {
    @Environment(AppModel.self) private var model

    private let sections = MacKeymap.default.helpSections()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: 3)

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    model.isHelpOpen = false
                }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Keyboard shortcuts")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text("Esc to close")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.headline)
                                .padding(.bottom, 2)
                            ForEach(section.items, id: \.command) { item in
                                HStack {
                                    Text(item.label)
                                    Spacer()
                                    Text(item.shortcut.isEmpty ? "—" : item.shortcut)
                                        .monospaced()
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(width: 880)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        }
    }
}
