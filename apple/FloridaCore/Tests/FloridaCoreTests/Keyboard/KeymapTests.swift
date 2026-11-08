import Foundation
import Testing
@testable import FloridaCore

@Suite struct KeymapTests {
    /// The complete expected default keymap. `defaultKeymapHasExactlyTheseBindings` ensures this
    /// table and `Keymap.default` never drift apart.
    static let expectedDefaults: [(String, AppCommand)] = [
        ("j", .focusNext),
        ("k", .focusPrevious),
        ("h", .previousDay),
        ("l", .nextDay),
        ("shift+h", .previousWeek),
        ("shift+l", .nextWeek),
        ("t", .today),
        ("g d", .goToDate),
        ("d", .viewDay),
        ("w", .viewWeek),
        ("3", .viewThreeDays),
        ("m", .viewMonth),
        ("cmd+t", .toggleTasks),
        ("g t", .goToTasks),
        ("g c", .goToCalendar),
        ("cmd+k", .commandPalette),
        ("/", .search),
        ("cmd+f", .search),
        ("?", .showHelp),
        ("c", .newTask),
        ("cmd+n", .newTask),
        ("shift+c", .newEvent),
        ("e", .edit),
        ("return", .edit),
        ("x", .delete),
        ("delete", .delete),
        ("space", .complete),
        ("p", .pin),
        ("shift+p", .unpin),
        ("s", .snooze),
        ("cmd+1", .setPriorityAsap),
        ("cmd+2", .setPriorityHigh),
        ("cmd+3", .setPriorityMedium),
        ("cmd+4", .setPriorityLow),
        ("o", .openInGoogle),
        ("cmd+shift+c", .copyLink),
        ("escape", .cancel),
        ("cmd+r", .sync),
    ]

    @Test(arguments: expectedDefaults)
    func defaultBinding(_ shortcut: String, _ command: AppCommand) throws {
        let sequence = try #require(KeyChord.sequence(parsing: shortcut))
        #expect(Keymap.default.command(for: sequence) == command, "\(shortcut) should map to \(command)")
        #expect(Keymap.default.bindings(for: command).contains(sequence))
    }

    @Test func defaultKeymapHasExactlyTheseBindings() throws {
        let expected = try Set(Self.expectedDefaults.map { try KeyBinding(#require(KeyChord.sequence(parsing: $0.0)), $0.1) })
        #expect(Set(Keymap.default.bindings) == expected)
        #expect(Keymap.default.bindings.count == Self.expectedDefaults.count)
    }

    @Test func defaultKeymapIsValid() {
        #expect(Keymap.default.validate() == [])
    }

    @Test func defaultKeymapIsPrefixFree() {
        let sequences = Keymap.default.bindings.map(\.sequence)
        for shorter in sequences {
            for longer in sequences where longer.count > shorter.count {
                #expect(!longer.starts(with: shorter), "\(shorter.shortcutDescription) is a prefix of \(longer.shortcutDescription)")
            }
        }
    }

    @Test func defaultKeymapHasNoDuplicateSequences() {
        let sequences = Keymap.default.bindings.map(\.sequence)
        #expect(Set(sequences).count == sequences.count)
    }

    @Test func everyCommandIsBoundByDefault() {
        for command in AppCommand.allCases {
            #expect(!Keymap.default.bindings(for: command).isEmpty, "\(command) has no default binding")
        }
    }

    @Test func validateReportsDuplicates() throws {
        let keymap = Keymap(bindings: [
            try #require(KeyBinding("j", .focusNext)),
            try #require(KeyBinding("j", .focusPrevious)),
        ])
        let problems = keymap.validate()
        #expect(problems.count == 1)
        #expect(problems.first?.contains("J") == true)
        #expect(problems.first?.contains("focusNext") == true)
        #expect(problems.first?.contains("focusPrevious") == true)
    }

    @Test func validateReportsPrefixConflicts() throws {
        let keymap = Keymap(bindings: [
            try #require(KeyBinding("g", .today)),
            try #require(KeyBinding("g d", .goToDate)),
        ])
        let problems = keymap.validate()
        #expect(problems.count == 1)
        #expect(problems.first?.contains("prefix") == true)
        #expect(problems.first?.contains("G D") == true)
    }

    @Test func validateReportsEmptySequences() {
        let problems = Keymap(bindings: [KeyBinding([], .today)]).validate()
        #expect(problems.count == 1)
        #expect(problems.first?.contains("empty") == true)
    }

    @Test func validatingInitThrows() throws {
        let duplicate = try #require(KeyBinding("j", .focusNext))
        #expect(throws: Keymap.ValidationError.self) {
            try Keymap(validating: [duplicate, duplicate])
        }
        let keymap = try Keymap(validating: Keymap.default.bindings)
        #expect(keymap == Keymap.default)
    }

    @Test func secondaryBindingsAreListedInOrder() throws {
        let search = Keymap.default.bindings(for: .search)
        #expect(search == [[KeyChord("/")], [KeyChord("f", [.command])]])
        #expect(Keymap.default.bindings(for: .newTask).count == 2)
        #expect(Keymap.default.bindings(for: .edit).map(\.shortcutDescription) == ["E", "↩"])
    }

    @Test func helpSectionsCoverEveryCommandWithLabels() {
        let sections = Keymap.default.helpSections()
        #expect(sections.map(\.title) == ["Navigation", "Views", "Panels", "Editing", "Actions"])
        let items = sections.flatMap(\.items)
        #expect(Set(items.map(\.command)) == Set(AppCommand.allCases))
        #expect(items.count == AppCommand.allCases.count)
        for item in items {
            #expect(!item.label.isEmpty)
            #expect(item.label == item.command.label)
            #expect(!item.shortcuts.isEmpty, "\(item.command) has no shortcut in the help overlay")
        }
        let byCommand = Dictionary(uniqueKeysWithValues: items.map { ($0.command, $0) })
        #expect(byCommand[.goToDate]?.shortcut == "G D")
        #expect(byCommand[.commandPalette]?.shortcut == "⌘K")
        #expect(byCommand[.search]?.shortcuts == ["/", "⌘F"])
        #expect(byCommand[.search]?.shortcut == "/, ⌘F")
        #expect(byCommand[.copyLink]?.shortcut == "⇧⌘C")
        #expect(byCommand[.cancel]?.shortcut == "Esc")
        #expect(byCommand[.complete]?.shortcut == "Space")
    }

    @Test func helpSectionsShowUnboundCommandsWithoutShortcuts() throws {
        let keymap = Keymap(bindings: [try #require(KeyBinding("j", .focusNext))])
        let items = keymap.helpSections().flatMap(\.items)
        #expect(items.count == AppCommand.allCases.count)
        #expect(items.first { $0.command == .focusPrevious }?.shortcuts == [])
        #expect(items.first { $0.command == .focusPrevious }?.shortcut == "")
    }

    @Test func priorityCommandsMapToModelPriorities() {
        #expect(AppCommand.setPriorityAsap.priority == .asap)
        #expect(AppCommand.setPriorityHigh.priority == .high)
        #expect(AppCommand.setPriorityMedium.priority == .medium)
        #expect(AppCommand.setPriorityLow.priority == .low)
        #expect(AppCommand.newTask.priority == nil)
    }
}
