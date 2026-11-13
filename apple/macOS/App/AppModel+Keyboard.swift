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
        if event.isARepeat, chord == KeyChord("space"), !(event.window?.firstResponder is NSText) { return true }

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
            if let editor = NSApplication.shared.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
                return false
            }
            if let editor = NSApplication.shared.keyWindow?.firstResponder as? NSTextView, editor.selectedRange().length > 0 {
                palette.suggestions = []
            }
            if !palette.suggestions.isEmpty {
                if chord == KeyChord("escape") {
                    dismissPaletteSuggestions()
                    return true
                }
                if chord == KeyChord("tab") || chord == KeyChord("return") {
                    completePaletteSuggestion()
                    return true
                }
                if chord == KeyChord("up") || chord == KeyChord("down") {
                    let delta = chord == KeyChord("up") ? -1 : 1
                    palette.suggestionIndex = (palette.suggestionIndex + delta + palette.suggestions.count) % palette.suggestions.count
                    return true
                }
            }
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
