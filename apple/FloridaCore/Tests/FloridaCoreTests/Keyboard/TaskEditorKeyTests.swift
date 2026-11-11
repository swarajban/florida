import Testing
@testable import FloridaCore

@Suite struct TaskEditorKeyTests {
    @Test func everyControlHasItsOwnKey() {
        let keys = TaskEditorKey.allCases.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    @Test func aKeyReachesItsControlWhenNothingIsFocused() {
        #expect(TaskEditorKey.press(for: KeyChord("d"), focus: .none) == .init(key: .due))
        #expect(TaskEditorKey.press(for: KeyChord("s"), focus: .none) == .init(key: .start))
        #expect(TaskEditorKey.press(for: KeyChord("space"), focus: .none) == .init(key: .markDone))
        #expect(TaskEditorKey.press(for: KeyChord("z"), focus: .none) == nil)
    }

    @Test func aTextFieldKeepsEveryKey() {
        for key in TaskEditorKey.allCases {
            #expect(TaskEditorKey.press(for: KeyChord(key.key), focus: .text) == nil)
        }
    }

    /// Typing "p" in a time is PM, and Space must not finish the task from inside a field.
    @Test func aDateFieldKeepsItsOwnKeysAndPassesTheRest() {
        #expect(TaskEditorKey.press(for: KeyChord("a"), focus: .date) == nil)
        #expect(TaskEditorKey.press(for: KeyChord("p"), focus: .date) == nil)
        #expect(TaskEditorKey.press(for: KeyChord("space"), focus: .date) == nil)
        #expect(TaskEditorKey.press(for: KeyChord("s"), focus: .date) == .init(key: .start))
        #expect(TaskEditorKey.press(for: KeyChord("c"), focus: .date) == .init(key: .category))
    }

    @Test func spacePressesAFocusedControlInsteadOfFinishingTheTask() {
        #expect(TaskEditorKey.press(for: KeyChord("space"), focus: .control) == nil)
        #expect(TaskEditorKey.press(for: KeyChord("p"), focus: .control) == .init(key: .priority))
    }

    @Test func shiftGoesBackwardOnlyWhereThereIsABackward() {
        #expect(TaskEditorKey.press(for: KeyChord("p", [.shift]), focus: .none) == .init(key: .priority, isShifted: true))
        #expect(TaskEditorKey.press(for: KeyChord("d", [.shift]), focus: .none) == .init(key: .due, isShifted: true))
        #expect(TaskEditorKey.press(for: KeyChord("t", [.shift]), focus: .none) == nil)
        #expect(TaskEditorKey.press(for: KeyChord("space", [.shift]), focus: .none) == nil)
    }

    /// ⌘S and friends belong to the menus.
    @Test func otherModifiersAreNotEditorKeys() {
        #expect(TaskEditorKey.press(for: KeyChord("s", [.command]), focus: .none) == nil)
        #expect(TaskEditorKey.press(for: KeyChord("d", [.option]), focus: .none) == nil)
        #expect(TaskEditorKey.press(for: KeyChord("d", [.control, .shift]), focus: .none) == nil)
    }

    @Test func stepWrapsInBothDirections() {
        let choices = ["asap", "high", "medium", "low"]
        #expect(TaskEditorKey.step("high", in: choices, backward: false) == "medium")
        #expect(TaskEditorKey.step("low", in: choices, backward: false) == "asap")
        #expect(TaskEditorKey.step("high", in: choices, backward: true) == "asap")
        #expect(TaskEditorKey.step("asap", in: choices, backward: true) == "low")
    }

    @Test func stepFromAnUnknownChoiceStartsAtTheFirst() {
        #expect(TaskEditorKey.step("gone", in: ["a", "b"], backward: false) == "a")
        #expect(TaskEditorKey.step("gone", in: ["a", "b"], backward: true) == "a")
        #expect(TaskEditorKey.step("only", in: [String](), backward: false) == "only")
        // "None" is a choice too: a task without a project steps onto the first project.
        let projects: [String?] = [nil, "p1", "p2"]
        #expect(TaskEditorKey.step(nil, in: projects, backward: false) == "p1")
        #expect(TaskEditorKey.step("p2", in: projects, backward: false) == nil)
    }
}
