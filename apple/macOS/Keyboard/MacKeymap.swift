import FloridaKit
import Foundation

/// A key sequence bound to a `MacCommand`.
struct MacKeyBinding: Hashable, Sendable {
    var sequence: KeySequence
    var command: MacCommand
}

/// FloridaCore's `Keymap.default` with the Mac-only bindings added and the shared bindings the
/// Mac rebinds removed. Must stay prefix-free, like the shared keymap.
struct MacKeymap: Sendable {
    var bindings: [MacKeyBinding]

    /// One row of the help overlay.
    struct HelpItem: Hashable {
        var command: MacCommand
        var label: String
        var shortcut: String
    }

    struct HelpSection: Hashable {
        var title: String
        var items: [HelpItem]
    }

    /// Shared sequences the Mac binds to something else: `m` is Move to… here, so the month
    /// view moves to ⇧M.
    static let overriddenSequences: Set<KeySequence> = [[KeyChord("m")]]

    static let macBindings: [(String, MacCommand)] = [
        ("u", .undo),
        ("m", .move),
        ("shift+m", .core(.viewMonth)),
        ("tab", .acceptSuggestion),
        ("shift+n", .newTaskEditor),
        ("n", .doNow),
        ("shift+space", .doneForNow),
        (".", .repeatLast),
        ("z z", .centerOnNow),
        ("g g", .jumpToFirst),
        ("shift+g", .jumpToLast),
        ("shift+e", .editEvent),
        ("r y", .respondYes),
        ("r m", .respondMaybe),
        ("r n", .respondNo),
    ]

    static let `default`: MacKeymap = {
        let shared = Keymap.default.bindings
            .filter { !overriddenSequences.contains($0.sequence) }
            .map { MacKeyBinding(sequence: $0.sequence, command: .core($0.command)) }
        let extra = macBindings.compactMap { shortcut, command in
            KeyChord.sequence(parsing: shortcut).map { MacKeyBinding(sequence: $0, command: command) }
        }
        let keymap = MacKeymap(bindings: shared + extra)
        assert(keymap.problems().isEmpty, keymap.problems().joined(separator: "\n"))
        return keymap
    }()

    func command(for sequence: KeySequence) -> MacCommand? {
        bindings.first { $0.sequence == sequence }?.command
    }

    func bindings(for command: MacCommand) -> [KeySequence] {
        bindings.filter { $0.command == command }.map(\.sequence)
    }

    /// "u", "⌘K, /" — every shortcut for `command`, in keymap order.
    func shortcut(for command: MacCommand) -> String {
        bindings(for: command).map(Self.display).joined(separator: ", ")
    }

    /// Duplicate sequences and sequences that are a prefix of another; empty when sound.
    func problems() -> [String] {
        var problems: [String] = []
        for (index, binding) in bindings.enumerated() {
            for other in bindings[(index + 1)...] where binding.sequence == other.sequence {
                problems.append("\(binding.sequence.shortcutDescription) is bound twice")
            }
            for other in bindings
            where binding.sequence.count < other.sequence.count && other.sequence.starts(with: binding.sequence) {
                problems.append("\(binding.sequence.shortcutDescription) is a prefix of \(other.sequence.shortcutDescription)")
            }
        }
        return problems
    }

    func helpSections() -> [HelpSection] {
        AppCommand.Section.allCases.compactMap { section in
            let items = MacCommand.all.filter { $0.section == section }.map { command in
                HelpItem(command: command, label: command.label, shortcut: shortcut(for: command))
            }
            return items.isEmpty ? nil : HelpSection(title: section.rawValue, items: items)
        }
    }

    /// How a sequence reads in the help, the palette and the status bar: plain letters stay
    /// lowercase as typed ("g d", "u"), shifted letters are capitals ("G", "H"), and chords with
    /// other modifiers use the glyph form ("⌘K").
    static func display(_ sequence: KeySequence) -> String {
        sequence.map(display).joined(separator: " ")
    }

    static func display(_ chord: KeyChord) -> String {
        if chord.key.count == 1, chord.key.first?.isLetter == true {
            if chord.modifiers.isEmpty { return chord.key }
            if chord.modifiers == [.shift] { return chord.key.uppercased() }
        }
        return chord.description
    }
}

/// Resolves multi-key sequences over a `MacKeymap`, the same way FloridaCore's
/// `KeySequenceMatcher` does for the shared keymap (which only knows `AppCommand`).
struct MacKeySequenceMatcher {
    enum Result: Hashable {
        case matched(MacCommand)
        case pending
        case unmatched
    }

    var keymap: MacKeymap
    /// Longest gap allowed between two chords of one sequence, in seconds.
    var timeout: TimeInterval = 1.0
    private(set) var pendingSequence: KeySequence = []
    private var lastChordTime: Date?

    init(keymap: MacKeymap) {
        self.keymap = keymap
    }

    mutating func feed(_ chord: KeyChord, at time: Date) -> Result {
        if let lastChordTime, !pendingSequence.isEmpty, time.timeIntervalSince(lastChordTime) > timeout {
            reset()
        }
        let candidate = pendingSequence + [chord]
        if let command = keymap.command(for: candidate) {
            reset()
            return .matched(command)
        }
        let continues = keymap.bindings.contains {
            $0.sequence.count > candidate.count && $0.sequence.starts(with: candidate)
        }
        if continues {
            pendingSequence = candidate
            lastChordTime = time
            return .pending
        }
        reset()
        return .unmatched
    }

    mutating func reset() {
        pendingSequence = []
        lastChordTime = nil
    }
}
