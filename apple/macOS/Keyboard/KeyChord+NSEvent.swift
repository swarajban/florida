import AppKit
import FloridaKit

extension KeyChord {
    /// The chord for a key-down event in the form `Keymap` bindings use: letters lowercased with
    /// `shift` as a modifier, other characters as the key the press produced ("?" rather than
    /// shift+/), special keys by name. Nil for presses without a usable key (dead keys, function
    /// keys, bare modifiers).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Set<Modifier> = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        if let name = KeyChord.namedKeys[event.keyCode] {
            if flags.contains(.shift) { modifiers.insert(.shift) }
            self.init(name, modifiers)
            return
        }

        // Shift is still applied here (shift+/ gives "?"); option and control are not (⌥c gives "c").
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let character = characters.first, let scalar = character.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), !character.isWhitespace
        else { return nil }

        if character.isLetter {
            if flags.contains(.shift) { modifiers.insert(.shift) }
            self.init(String(character).lowercased(), modifiers)
        } else {
            self.init(String(character), modifiers)
        }
    }

    /// Virtual key codes of the named keys `KeyChord(parsing:)` knows.
    static let namedKeys: [UInt16: String] = [
        53: "escape",
        36: "return", 76: "return",
        48: "tab",
        49: "space",
        51: "delete", 117: "delete",
        126: "up", 125: "down", 123: "left", 124: "right",
    ]
}
