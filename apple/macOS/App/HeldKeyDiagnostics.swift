#if DEBUG
import AppKit
import SwiftUI

struct HeldKeyDiagnostics: View {
    let keys: [String]
    @State private var runningKey: String?
    @State private var finishedKey: String?

    var body: some View {
        if UserDefaults.standard.bool(forKey: "demoData"),
           UserDefaults.standard.bool(forKey: "uiHeldKeyDiagnostics") {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Button("Hold \(key)") { hold(key) }
                        .accessibilityIdentifier("inject-held-\(key)")
                        .disabled(runningKey != nil)
                }
                if let finishedKey {
                    Text("Held \(finishedKey) finished")
                        .accessibilityIdentifier("held-key-finished-\(finishedKey)")
                }
            }
            .font(.caption2)
        }
    }

    private func hold(_ key: String) {
        let codes: [String: UInt16] = ["t": 17, "x": 7, "z": 6, "c": 8, "/": 44, "1": 18]
        guard let window = NSApp.keyWindow, let code = codes[key], runningKey == nil else { return }
        runningKey = key
        finishedKey = nil
        Task { @MainActor in
            defer { runningKey = nil }
            @MainActor func post(_ type: NSEvent.EventType, repeats: Bool = false) -> Bool {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key,
                    charactersIgnoringModifiers: key, isARepeat: repeats, keyCode: code)
                else { return false }
                NSApp.postEvent(event, atStart: false)
                return true
            }
            guard post(.keyDown) else { finishedKey = "invalid"; return }
            try? await Task.sleep(for: .milliseconds(500))
            for _ in 0..<3 {
                guard post(.keyDown, repeats: true) else { finishedKey = "invalid"; return }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard post(.keyUp) else { finishedKey = "invalid"; return }
            try? await Task.sleep(for: .milliseconds(150))
            finishedKey = key
        }
    }
}
#endif
