import AppKit
import FloridaKit

extension AppModel {
    /// Routes one key-down event from the main window; returns true when the app consumed it.
    /// Runs synchronously on the main actor from the local event monitor, so every state change
    /// lands before the next event arrives.
    ///
    /// A sheet (editor, go to date) owns the keyboard except for Escape. While typing elsewhere
    /// (the palette or any focused text view) only ⌘ chords and Escape reach the keymap; the
    /// palette additionally takes ↑ / ↓ for its result list.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord(event: event) else { return false }
        let isCommandChord = chord.modifiers.contains(.command)
        let isEscape = chord == KeyChord("escape")

        if editorTask != nil || isGoToDateOpen {
            guard isEscape else { return false }
            cancel()
            return true
        }

        if isHelpOpen, !isCommandChord {
            isHelpOpen = false
            if isEscape || chord == KeyChord("?") {
                return true
            }
        }

        if isPaletteOpen {
            if chord == KeyChord("up") {
                palette.moveSelection(by: -1)
                return true
            }
            if chord == KeyChord("down") {
                palette.moveSelection(by: 1)
                return true
            }
        }

        let typing = isPaletteOpen || NSApplication.shared.keyWindow?.firstResponder is NSTextView
        if typing, !isCommandChord, !isEscape {
            if !matcher.pendingSequence.isEmpty {
                matcher.reset()
                pendingKeys = ""
            }
            return false
        }

        switch matcher.feed(chord, at: Date()) {
        case .matched(let command):
            pendingKeys = ""
            perform(command)
            return true
        case .pending:
            pendingKeys = matcher.pendingSequence.shortcutDescription
            return true
        case .unmatched:
            pendingKeys = ""
            return false
        }
    }
}
