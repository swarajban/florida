import FloridaKit
import Testing

struct CalendarShortcutTests {
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
