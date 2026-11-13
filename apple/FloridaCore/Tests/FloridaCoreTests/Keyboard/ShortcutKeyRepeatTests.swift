import Testing
@testable import FloridaCore

@Suite struct ShortcutKeyRepeatTests {
    @Test func handledShortcutDoesNotRepeatAfterFocusMoves() {
        var gate = ShortcutKeyRepeat()
        #expect(gate.keyDown(keyCode: 17, isRepeat: false) == false)
        gate.didHandle(keyCode: 17)
        #expect(gate.keyDown(keyCode: 17, isRepeat: true) == true)
        #expect(gate.keyDown(keyCode: 17, isRepeat: true) == true)
        gate.keyUp(keyCode: 17)
        #expect(gate.keyDown(keyCode: 17, isRepeat: false) == false)
        #expect(gate.keyDown(keyCode: 17, isRepeat: true) == false)
    }

    @Test func nativeTypingRepeatsWithoutAHandledShortcut() {
        var gate = ShortcutKeyRepeat()
        #expect(gate.keyDown(keyCode: 17, isRepeat: false) == false)
        #expect(gate.keyDown(keyCode: 17, isRepeat: true) == false)
    }

    @Test func aFreshPressRecoversEvenWhenKeyUpWasInAnotherWindow() {
        var gate = ShortcutKeyRepeat()
        gate.didHandle(keyCode: 17)
        #expect(gate.keyDown(keyCode: 17, isRepeat: true) == true)
        #expect(gate.keyDown(keyCode: 17, isRepeat: false) == false)
        #expect(gate.keyDown(keyCode: 17, isRepeat: true) == false)
    }

    @Test func keyUpReleasesOnlyItsOwnPhysicalKey() {
        var gate = ShortcutKeyRepeat()
        gate.didHandle(keyCode: 17)
        gate.didHandle(keyCode: 7)
        gate.keyUp(keyCode: 17)
        #expect(gate.keyDown(keyCode: 17, isRepeat: true) == false)
        #expect(gate.keyDown(keyCode: 7, isRepeat: true) == true)
    }

    @Test(arguments: ["h", "j", "k", "l", "[", "]", "up", "down", "left", "right"])
    func navigationStillRepeats(key: String) {
        for modifiers: Set<KeyChord.Modifier> in [[], [.shift]] {
            var gate = ShortcutKeyRepeat()
            #expect(ShortcutKeyRepeat.isNavigation(KeyChord(key, modifiers)))
            #expect(gate.keyDown(keyCode: 17, isRepeat: false) == false)
            #expect(gate.keyDown(keyCode: 17, isRepeat: true) == false)
        }
    }

    @Test func modifiedLettersAreNotMistakenForNavigation() {
        var gate = ShortcutKeyRepeat()
        #expect(!ShortcutKeyRepeat.isNavigation(KeyChord("k", [.command])))
        gate.didHandle(keyCode: 40)
        #expect(gate.keyDown(keyCode: 40, isRepeat: true) == true)
        #expect(gate.keyDown(keyCode: 17, isRepeat: true) == false)
        #expect(!ShortcutKeyRepeat.isNavigation(KeyChord("h", [.option])))
        #expect(!ShortcutKeyRepeat.isNavigation(KeyChord("j", [.control])))
    }
}
