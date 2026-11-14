#if DEBUG
import AppKit
import SwiftUI

struct InteractionModeDiagnostics: View {
    @Environment(AppModel.self) private var model
    @State private var injection: Task<Void, Never>?
    @State private var injectionStatus = "idle"
    @State private var visibilitySnapshot = "unread"

    var body: some View {
        if UserDefaults.standard.bool(forKey: "demoData"),
           UserDefaults.standard.bool(forKey: "uiInteractionModeDiagnostics") {
            HStack(spacing: 4) {
                Button("Drag Esc") { arm("escape") }
                    .accessibilityIdentifier("mode-arm-drag-escape")
                Button("Drag Month") { arm("month") }
                    .accessibilityIdentifier("mode-arm-drag-month")
                Button("Rows") {
                    visibilitySnapshot = model.paneItemsOnScreen.map { String(describing: $0) }.sorted().joined(separator: ",")
                    if visibilitySnapshot.isEmpty { visibilitySnapshot = "none" }
                }
                .accessibilityIdentifier("mode-snapshot-rows")
                Text(visibilitySnapshot)
                    .lineLimit(1)
                    .frame(maxWidth: 70)
                    .accessibilityIdentifier("mode-visible-rows")
                    .accessibilityValue(visibilitySnapshot)
                Text(injectionStatus)
                    .accessibilityIdentifier("mode-drag-injection")
                    .accessibilityValue(injectionStatus)
                Text(model.gridDrag == nil ? "none" : "dragging")
                    .accessibilityIdentifier("mode-active-drag")
                    .accessibilityValue(model.gridDrag == nil ? "none" : "dragging")
                Text(model.viewMode.rawValue)
                    .accessibilityIdentifier("mode-calendar-view")
                    .accessibilityValue(model.viewMode.rawValue)
                Text(model.selection.map { String(describing: $0) } ?? "none")
                    .lineLimit(1)
                    .frame(maxWidth: 60)
                    .accessibilityIdentifier("mode-selection")
                    .accessibilityValue(model.selection.map { String(describing: $0) } ?? "none")
            }
            .font(.caption2)
            .onDisappear { injection?.cancel() }
        }
    }

    private func arm(_ key: String) {
        injection?.cancel()
        injectionStatus = "armed"
        injection = Task { @MainActor in
            for _ in 0..<300 {
                guard !Task.isCancelled else { return }
                if let drag = model.gridDrag, !drag.isDropped, let window = model.mainWindow {
                    let characters = key == "escape" ? "\u{1b}" : "M"
                    let flags: NSEvent.ModifierFlags = key == "escape" ? [] : [.shift]
                    let code: UInt16 = key == "escape" ? 53 : 46
                    for type: NSEvent.EventType in [.keyDown, .keyUp] {
                        guard let event = NSEvent.keyEvent(
                            with: type, location: .zero, modifierFlags: flags,
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: characters,
                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
                        else { injectionStatus = "invalid"; return }
                        NSApp.postEvent(event, atStart: false)
                    }
                    injectionStatus = "sent"
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }
            injectionStatus = "timed out"
        }
    }
}
#endif
