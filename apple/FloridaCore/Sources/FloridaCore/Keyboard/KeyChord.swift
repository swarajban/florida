import Foundation

/// One key press: a key plus the modifiers held with it. The macOS app turns each `NSEvent` into a
/// chord; this package only compares, parses and prints them.
///
/// Letters are passed lowercased with `shift` as a modifier ("shift+j"). Shifted symbols are passed
/// as the produced character without `shift` ("?" rather than shift+/), so that bindings read the way
/// users type them.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public enum Modifier: String, Hashable, Sendable, CaseIterable, Comparable {
        case command, shift, option, control

        /// The macOS glyph: ⌘ ⇧ ⌥ ⌃.
        public var symbol: Character {
            switch self {
            case .command: "⌘"
            case .shift: "⇧"
            case .option: "⌥"
            case .control: "⌃"
            }
        }

        /// Position in the macOS display order: control, option, shift, command.
        public var displayRank: Int {
            switch self {
            case .control: 0
            case .option: 1
            case .shift: 2
            case .command: 3
            }
        }

        public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
            lhs.displayRank < rhs.displayRank
        }

        /// Accepts cmd/command/⌘, shift/⇧, opt/option/alt/⌥ and ctrl/control/⌃, case-insensitively.
        public init?(parsing text: String) {
            switch text.lowercased() {
            case "cmd", "command", "⌘": self = .command
            case "shift", "⇧": self = .shift
            case "opt", "option", "alt", "⌥": self = .option
            case "ctrl", "control", "⌃": self = .control
            default: return nil
            }
        }
    }

    /// Lowercased character ("k", "/", "1") or a named key: "escape", "return", "tab", "space",
    /// "delete", "up", "down", "left", "right".
    public var key: String
    public var modifiers: Set<Modifier>

    /// `key` is lowercased; named keys must already use their canonical name.
    public init(_ key: String, _ modifiers: Set<Modifier> = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Parses "cmd+k", "shift+j", "ctrl+opt+x", "g", "escape", "?", and the glyph form produced by
    /// `description` such as "⇧⌘C" or "Esc". Returns nil for empty text, an unknown modifier, or a
    /// modifier used as the key.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var modifiers: Set<Modifier> = []
        var keyText: String

        if trimmed.count > 1, trimmed.contains("+") {
            var parts = trimmed.split(separator: "+", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
                // "cmd++": the key is the plus sign itself.
                parts.removeLast(2)
                keyText = "+"
            } else {
                keyText = parts.removeLast()
            }
            for part in parts {
                guard let modifier = Modifier(parsing: part) else { return nil }
                modifiers.insert(modifier)
            }
        } else {
            // Glyph form such as "⇧⌘C": leading modifier symbols, then the key.
            var rest = Substring(trimmed)
            while rest.count > 1, let first = rest.first, let modifier = Modifier(parsing: String(first)) {
                modifiers.insert(modifier)
                rest.removeFirst()
            }
            keyText = String(rest)
        }

        guard let key = KeyChord.canonicalKey(keyText) else { return nil }
        self.init(key, modifiers)
    }

    /// Canonical form: modifier glyphs in the order control, option, shift, command, then the key,
    /// e.g. "⌘K", "⇧J", "G", "Esc", "Space", "⌃⌥⇧⌘A".
    public var description: String {
        let glyphs = modifiers.sorted().map { String($0.symbol) }.joined()
        return glyphs + (KeyChord.keyDisplayNames[key] ?? key.uppercased())
    }

    /// Parses a whitespace-separated sequence such as "g d" or "cmd+k". Nil if any chord fails to parse.
    public static func sequence(parsing text: String) -> KeySequence? {
        let chords = text.split(whereSeparator: \.isWhitespace).map { KeyChord(parsing: String($0)) }
        guard !chords.isEmpty, chords.allSatisfy({ $0 != nil }) else { return nil }
        return chords.compactMap { $0 }
    }

    /// Lowercases and resolves aliases ("esc" → "escape"). Nil for empty text, text containing
    /// whitespace, or a modifier name.
    static func canonicalKey(_ text: String) -> String? {
        let lowered = text.lowercased()
        guard !lowered.isEmpty, !lowered.contains(where: \.isWhitespace), Modifier(parsing: lowered) == nil else {
            return nil
        }
        return keyAliases[lowered] ?? lowered
    }

    static let keyAliases: [String: String] = [
        "esc": "escape", "⎋": "escape",
        "enter": "return", "↩": "return", "⏎": "return",
        "⇥": "tab",
        "spacebar": "space", "␣": "space",
        "backspace": "delete", "⌫": "delete",
        "arrowup": "up", "↑": "up",
        "arrowdown": "down", "↓": "down",
        "arrowleft": "left", "←": "left",
        "arrowright": "right", "→": "right",
    ]

    static let keyDisplayNames: [String: String] = [
        "escape": "Esc", "return": "↩", "tab": "⇥", "space": "Space", "delete": "⌫",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
    ]
}

public typealias KeySequence = [KeyChord]

extension Array where Element == KeyChord {
    /// Space-separated chord descriptions, e.g. "G D" or "⌘K".
    public var shortcutDescription: String {
        map(\.description).joined(separator: " ")
    }
}
