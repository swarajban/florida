import AppKit
import FloridaKit

extension AppModel {
    /// Routes one key-down event from the main window; returns true when the app consumed it.
    /// Runs synchronously on the main actor from the local event monitor, so every state change
    /// lands before the next event arrives.
    ///
    /// A sheet (editor, go to date) owns the keyboard except for Escape. While typing elsewhere
    /// (the palette or any focused text view) only ⌘ chords and Escape reach the keymap; the
    /// palette additionally takes ↑ / ↓ for its result list, ⇥ to create quick add's unknown
    /// `#category`, and ⌘↩ to parse quick add's text with AI in the full editor.
    ///
    /// `inEventPopover` marks events from an event's detail popover, which is its own window:
    /// only the commands that act on the open event run from there (`actsOnOpenEvent`); other
    /// keys stay with the popover's own controls.
    ///
    /// Jump mode (`f`) takes every key while its labels are up, except ⌘ chords: see
    /// `handleJumpKey`.
    func handleKeyDown(_ event: NSEvent, inEventPopover: Bool = false) -> Bool {
        guard let chord = KeyChord(event: event) else { return false }
        let isCommandChord = chord.modifiers.contains(.command)
        let isEscape = chord == KeyChord("escape")

        if isAvailabilityZoneOpen {
            if isEscape { isAvailabilityZoneOpen = false }
            return isEscape
        }
        if availabilityShare != nil, !isAvailabilityZoneOpen {
            return handleAvailabilityKey(chord)
        }

        if isSheetOpen {
            guard isEscape else { return false }
            cancel()
            return true
        }

        if handleJumpKey(chord) {
            return true
        }

        if handleEventResourceKey(chord) {
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
            if chord == KeyChord("return", [.command]), palette.mode == .quickAdd {
                parsePaletteWithAI()
                return true
            }
            if chord == KeyChord("tab"), palette.mode == .quickAdd, paletteUnknownHint != nil {
                createCategoryFromHint()
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
            if inEventPopover, !command.actsOnOpenEvent {
                return false
            }
            run(command)
            return true
        case .pending:
            pendingKeys = MacKeymap.display(matcher.pendingSequence) + " …"
            return true
        case .unmatched:
            pendingKeys = ""
            return false
        }
    }
}
