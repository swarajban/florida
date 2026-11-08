import Foundation

/// A key sequence (one or more chords typed in a row) bound to a command.
public struct KeyBinding: Hashable, Sendable {
    public var sequence: KeySequence
    public var command: AppCommand

    public init(_ sequence: KeySequence, _ command: AppCommand) {
        self.sequence = sequence
        self.command = command
    }

    /// Parses a whitespace-separated shortcut such as "g d" or "cmd+shift+c".
    public init?(_ shortcut: String, _ command: AppCommand) {
        guard let sequence = KeyChord.sequence(parsing: shortcut) else { return nil }
        self.init(sequence, command)
    }

    /// Display form, e.g. "G D" or "⇧⌘C".
    public var shortcutDescription: String { sequence.shortcutDescription }
}

/// The full set of bindings. Lookups are linear; keymaps are small.
public struct Keymap: Hashable, Sendable {
    public struct ValidationError: Error, Hashable, Sendable, CustomStringConvertible {
        public var problems: [String]

        public init(problems: [String]) {
            self.problems = problems
        }

        public var description: String { problems.joined(separator: "\n") }
    }

    /// One row of the help overlay.
    public struct HelpItem: Hashable, Sendable {
        public var command: AppCommand
        public var label: String
        /// Every shortcut bound to the command, in keymap order, e.g. ["/", "⌘F"]. Empty when unbound.
        public var shortcuts: [String]

        public init(command: AppCommand, label: String, shortcuts: [String]) {
            self.command = command
            self.label = label
            self.shortcuts = shortcuts
        }

        /// The shortcuts joined for a single-column layout, e.g. "/, ⌘F".
        public var shortcut: String { shortcuts.joined(separator: ", ") }
    }

    public struct HelpSection: Hashable, Sendable {
        public var title: String
        public var items: [HelpItem]

        public init(title: String, items: [HelpItem]) {
            self.title = title
            self.items = items
        }
    }

    public var bindings: [KeyBinding]

    public init(bindings: [KeyBinding]) {
        self.bindings = bindings
    }

    /// Like `init(bindings:)` but throws `ValidationError` when `validate()` reports problems.
    public init(validating bindings: [KeyBinding]) throws {
        self.init(bindings: bindings)
        let problems = validate()
        if !problems.isEmpty {
            throw ValidationError(problems: problems)
        }
    }

    /// Every sequence bound to `command`, in keymap order.
    public func bindings(for command: AppCommand) -> [KeySequence] {
        bindings.filter { $0.command == command }.map(\.sequence)
    }

    /// The command bound to exactly `sequence`, if any.
    public func command(for sequence: KeySequence) -> AppCommand? {
        bindings.first { $0.sequence == sequence }?.command
    }

    /// Problems that would make matching ambiguous: empty sequences, the same sequence bound twice,
    /// and a sequence that is a strict prefix of another (the matcher could never tell "g" from "g d").
    /// Empty when the keymap is sound; `Keymap.default` must always pass.
    public func validate() -> [String] {
        var problems: [String] = []

        for binding in bindings where binding.sequence.isEmpty {
            problems.append("empty sequence bound to \(binding.command.rawValue)")
        }

        var seen: [KeySequence: AppCommand] = [:]
        for binding in bindings where !binding.sequence.isEmpty {
            if let prior = seen[binding.sequence] {
                problems.append(
                    "\"\(binding.shortcutDescription)\" is bound to both \(prior.rawValue) and \(binding.command.rawValue)")
            } else {
                seen[binding.sequence] = binding.command
            }
        }

        for shorter in bindings {
            for longer in bindings
            where shorter.sequence.count < longer.sequence.count && longer.sequence.starts(with: shorter.sequence) {
                problems.append(
                    "\"\(shorter.shortcutDescription)\" (\(shorter.command.rawValue)) is a prefix of "
                        + "\"\(longer.shortcutDescription)\" (\(longer.command.rawValue))")
            }
        }

        return problems
    }

    /// Rows for the help overlay: every `AppCommand` grouped by `AppCommand.Section`, in declaration
    /// order, with its label and the shortcuts bound here (empty `shortcuts` when unbound).
    public func helpSections() -> [HelpSection] {
        AppCommand.Section.allCases.compactMap { section -> HelpSection? in
            let items = AppCommand.allCases.filter { $0.section == section }.map { command in
                HelpItem(
                    command: command, label: command.label,
                    shortcuts: bindings(for: command).map(\.shortcutDescription))
            }
            return items.isEmpty ? nil : HelpSection(title: section.rawValue, items: items)
        }
    }

    /// The Vimcal-style defaults. Plain digits select views; priorities use ⌘1…⌘4 so that "3" stays
    /// free for the 3-day view.
    public static let `default` = Keymap(bindings: [
        // Navigation
        bind("j", .focusNext),
        bind("k", .focusPrevious),
        bind("h", .previousDay),
        bind("l", .nextDay),
        bind("shift+h", .previousWeek),
        bind("shift+l", .nextWeek),
        bind("t", .today),
        bind("g d", .goToDate),
        // Views
        bind("d", .viewDay),
        bind("w", .viewWeek),
        bind("3", .viewThreeDays),
        bind("m", .viewMonth),
        // Panels
        bind("cmd+t", .toggleTasks),
        bind("g t", .goToTasks),
        bind("g c", .goToCalendar),
        bind("cmd+k", .commandPalette),
        bind("/", .search),
        bind("cmd+f", .search),
        bind("?", .showHelp),
        // Editing
        bind("c", .newTask),
        bind("cmd+n", .newTask),
        bind("shift+c", .newEvent),
        bind("e", .edit),
        bind("return", .edit),
        bind("x", .delete),
        bind("delete", .delete),
        bind("space", .complete),
        bind("p", .pin),
        bind("shift+p", .unpin),
        bind("s", .snooze),
        bind("cmd+1", .setPriorityAsap),
        bind("cmd+2", .setPriorityHigh),
        bind("cmd+3", .setPriorityMedium),
        bind("cmd+4", .setPriorityLow),
        // Actions
        bind("o", .openInGoogle),
        bind("cmd+shift+c", .copyLink),
        bind("escape", .cancel),
        bind("cmd+r", .sync),
    ])

    private static func bind(_ shortcut: String, _ command: AppCommand) -> KeyBinding {
        guard let binding = KeyBinding(shortcut, command) else {
            preconditionFailure("invalid default shortcut \"\(shortcut)\" for \(command.rawValue)")
        }
        return binding
    }
}
