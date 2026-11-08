import Foundation
import Testing
@testable import FloridaCore

@Suite struct KeyChordTests {
    @Test func parsesModifierNamesAndAliases() {
        #expect(KeyChord(parsing: "cmd+k") == KeyChord("k", [.command]))
        #expect(KeyChord(parsing: "command+k") == KeyChord("k", [.command]))
        #expect(KeyChord(parsing: "shift+j") == KeyChord("j", [.shift]))
        #expect(KeyChord(parsing: "ctrl+opt+x") == KeyChord("x", [.control, .option]))
        #expect(KeyChord(parsing: "control+option+x") == KeyChord("x", [.control, .option]))
        #expect(KeyChord(parsing: "alt+x") == KeyChord("x", [.option]))
        #expect(KeyChord(parsing: "cmd+shift+c") == KeyChord("c", [.command, .shift]))
        #expect(KeyChord(parsing: "CMD+K") == KeyChord("k", [.command]))
        #expect(KeyChord(parsing: " cmd + k ") == KeyChord("k", [.command]))
    }

    @Test func parsesBareKeysAndSymbols() {
        #expect(KeyChord(parsing: "g") == KeyChord("g"))
        #expect(KeyChord(parsing: "G") == KeyChord("g"))
        #expect(KeyChord(parsing: "?") == KeyChord("?"))
        #expect(KeyChord(parsing: "/") == KeyChord("/"))
        #expect(KeyChord(parsing: "1") == KeyChord("1"))
        #expect(KeyChord(parsing: "+") == KeyChord("+"))
        #expect(KeyChord(parsing: "cmd++") == KeyChord("+", [.command]))
    }

    @Test func parsesNamedKeys() {
        #expect(KeyChord(parsing: "escape") == KeyChord("escape"))
        #expect(KeyChord(parsing: "esc") == KeyChord("escape"))
        #expect(KeyChord(parsing: "Esc") == KeyChord("escape"))
        #expect(KeyChord(parsing: "return") == KeyChord("return"))
        #expect(KeyChord(parsing: "enter") == KeyChord("return"))
        #expect(KeyChord(parsing: "space") == KeyChord("space"))
        #expect(KeyChord(parsing: "delete") == KeyChord("delete"))
        #expect(KeyChord(parsing: "backspace") == KeyChord("delete"))
        #expect(KeyChord(parsing: "tab") == KeyChord("tab"))
        #expect(KeyChord(parsing: "up") == KeyChord("up"))
        #expect(KeyChord(parsing: "cmd+return") == KeyChord("return", [.command]))
    }

    @Test func parsesGlyphForm() {
        #expect(KeyChord(parsing: "⌘K") == KeyChord("k", [.command]))
        #expect(KeyChord(parsing: "⇧J") == KeyChord("j", [.shift]))
        #expect(KeyChord(parsing: "⇧⌘C") == KeyChord("c", [.command, .shift]))
        #expect(KeyChord(parsing: "⌃⌥X") == KeyChord("x", [.control, .option]))
        #expect(KeyChord(parsing: "⌘+k") == KeyChord("k", [.command]))
    }

    @Test func rejectsEmptyAndUnknownModifiers() {
        #expect(KeyChord(parsing: "") == nil)
        #expect(KeyChord(parsing: "   ") == nil)
        #expect(KeyChord(parsing: "foo+k") == nil)
        #expect(KeyChord(parsing: "cmd+") == nil)
        #expect(KeyChord(parsing: "cmd+shift") == nil)
        #expect(KeyChord(parsing: "shift") == nil)
        #expect(KeyChord(parsing: "⌘") == nil)
    }

    @Test func describesInMacOSOrder() {
        #expect(KeyChord("k", [.command]).description == "⌘K")
        #expect(KeyChord("j", [.shift]).description == "⇧J")
        #expect(KeyChord("g").description == "G")
        #expect(KeyChord("escape").description == "Esc")
        #expect(KeyChord("space").description == "Space")
        #expect(KeyChord("return").description == "↩")
        #expect(KeyChord("delete").description == "⌫")
        #expect(KeyChord("?").description == "?")
        #expect(KeyChord("c", [.command, .shift]).description == "⇧⌘C")
        #expect(KeyChord("a", [.command, .shift, .option, .control]).description == "⌃⌥⇧⌘A")
    }

    @Test func modifiersSortInDisplayOrder() {
        #expect(KeyChord.Modifier.allCases.sorted() == [.control, .option, .shift, .command])
    }

    @Test(arguments: ["cmd+k", "shift+j", "ctrl+opt+x", "g", "escape", "?", "return", "space", "delete", "cmd+shift+c", "up"])
    func descriptionRoundTrips(_ shortcut: String) throws {
        let chord = try #require(KeyChord(parsing: shortcut))
        #expect(KeyChord(parsing: chord.description) == chord)
    }

    @Test func initLowercasesKey() {
        #expect(KeyChord("K") == KeyChord("k"))
        #expect(KeyChord("Escape").key == "escape")
    }

    @Test func parsesSequences() {
        #expect(KeyChord.sequence(parsing: "g d") == [KeyChord("g"), KeyChord("d")])
        #expect(KeyChord.sequence(parsing: "cmd+k") == [KeyChord("k", [.command])])
        #expect(KeyChord.sequence(parsing: "  g   t ") == [KeyChord("g"), KeyChord("t")])
        #expect(KeyChord.sequence(parsing: "") == nil)
        #expect(KeyChord.sequence(parsing: "g bogus+d") == nil)
        #expect([KeyChord("g"), KeyChord("d")].shortcutDescription == "G D")
    }
}
