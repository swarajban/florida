import FloridaKit
import Testing

struct CalendarShortcutTests {
    @Test(arguments: [
        (AppCommand.previousWeek, ["[", "⌘←", "⇧H"]),
        (AppCommand.nextWeek, ["]", "⌘→", "⇧L"]),
    ])
    func weekShortcutsShowInHelpAndPalette(_ core: AppCommand, _ shortcuts: [String]) {
        let command = MacCommand.core(core)
        let keymap = MacKeymap.default
        #expect(keymap.problems().isEmpty)
        #expect(keymap.bindings(for: command).map(MacKeymap.display) == shortcuts)
        #expect(MacCommand.paletteCommands.contains(command))
        #expect(keymap.shortcut(for: command) == shortcuts.joined(separator: ", "))
        let help = keymap.helpSections().flatMap(\.items).first { $0.command == command }
        #expect(help?.shortcut == keymap.shortcut(for: command))
    }

    @Test func calendarsIsReachableFromTheKeymapPaletteAndHelp() {
        let keymap = MacKeymap.default
        let chord = KeyChord("l", [.command, .shift])
        #expect(keymap.problems().isEmpty)
        #expect(keymap.command(for: [chord]) == .toggleCalendars)
        let paletteResults = FuzzyMatch.filter(MacCommand.paletteCommands, query: "calendars", label: \.label)
        #expect(paletteResults.first == .toggleCalendars)
        let help = keymap.helpSections().flatMap(\.items).first { $0.command == .toggleCalendars }
        #expect(help?.shortcut == "⇧⌘L")
    }
}
