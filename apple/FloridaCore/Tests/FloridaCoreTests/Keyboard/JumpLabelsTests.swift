import Testing
@testable import FloridaCore

@Suite struct JumpLabelsTests {
    let abc: [Character] = ["a", "b", "c"]

    @Test func oneKeyEachWhileTheAlphabetLasts() {
        #expect(JumpAlphabet.labels(count: 0, alphabet: abc) == [])
        #expect(JumpAlphabet.labels(count: 2, alphabet: abc) == ["a", "b"])
        #expect(JumpAlphabet.labels(count: 3, alphabet: abc) == ["a", "b", "c"])
    }

    @Test func lastKeysBecomePrefixesOnlyAsNeeded() {
        // One more than the alphabet: "c" stops being a label and starts two.
        #expect(JumpAlphabet.labels(count: 4, alphabet: abc) == ["a", "b", "ca", "cb"])
        #expect(JumpAlphabet.labels(count: 5, alphabet: abc) == ["a", "b", "ca", "cb", "cc"])
        // One prefix reaches five; the sixth item costs "b" as well.
        #expect(JumpAlphabet.labels(count: 6, alphabet: abc) == ["a", "ba", "bb", "bc", "ca", "cb"])
        #expect(JumpAlphabet.labels(count: 9, alphabet: abc) == ["aa", "ab", "ac", "ba", "bb", "bc", "ca", "cb", "cc"])
    }

    @Test func stopsAtWhatTwoKeysReach() {
        #expect(JumpAlphabet.labels(count: 10, alphabet: abc).count == 9)
        #expect(JumpAlphabet.labels(count: 5, alphabet: ["a"]).count == 1)
        #expect(JumpAlphabet.labels(count: 5, alphabet: []) == [])
    }

    @Test func standardAlphabetStartsOnTheHomeRow() {
        let size = JumpAlphabet.standard.count
        #expect(size == 36)
        #expect(Set(JumpAlphabet.standard).count == size)
        #expect(JumpAlphabet.labels(count: 4) == ["a", "s", "d", "f"])
        #expect(JumpAlphabet.labels(count: size).allSatisfy { $0.count == 1 })
        // The 37th item turns only the last key, "0", into a prefix.
        let over = JumpAlphabet.labels(count: size + 1)
        #expect(over.prefix(size - 1).allSatisfy { $0.count == 1 })
        #expect(over.suffix(2) == ["0a", "0s"])
    }

    @Test func everyCountIsUniqueAndPrefixFree() {
        let alphabet: [Character] = ["a", "b", "c", "d"]
        for count in 0...20 {
            let labels = JumpAlphabet.labels(count: count, alphabet: alphabet)
            #expect(labels.count == min(count, 16), "count \(count)")
            #expect(Set(labels).count == labels.count, "count \(count)")
            for label in labels {
                for other in labels where other != label {
                    #expect(!other.hasPrefix(label), "\(label) starts \(other) at count \(count)")
                }
            }
        }
    }

    @Test func oneKeySelects() {
        var jump = JumpLabels(items: ["standup", "dentist", "gym"], alphabet: abc)
        #expect(jump.remaining == ["standup": "a", "dentist": "b", "gym": "c"])
        #expect(jump.type("b") == .selected("dentist"))
    }

    @Test func twoKeysNarrowThenSelect() {
        var jump = JumpLabels(items: ["one", "two", "three", "four"], alphabet: abc)
        #expect(jump.remaining == ["one": "a", "two": "b", "three": "ca", "four": "cb"])
        #expect(jump.type("c") == .pending)
        // Only the labels that start with "c" are left, less the key typed.
        #expect(jump.remaining == ["three": "a", "four": "b"])
        #expect(jump.type("b") == .selected("four"))
    }

    @Test func aKeyNoLabelStartsWithIsUnmatched() {
        var jump = JumpLabels(items: ["one", "two", "three", "four"], alphabet: abc)
        #expect(jump.type("x") == .unmatched)
        #expect(jump.remaining.count == 4)
        #expect(jump.type("c") == .pending)
        // "c" then "c": no label, even though "c" starts two of them.
        #expect(jump.type("c") == .unmatched)
        #expect(jump.remaining == ["three": "a", "four": "b"])
        #expect(jump.type("") == .unmatched)
    }

    @Test func keysCompareWithoutCase() {
        var jump = JumpLabels(items: ["one", "two"], alphabet: abc)
        #expect(jump.type("B") == .selected("two"))
    }

    @Test func anItemListedTwiceKeepsItsFirstLabel() {
        // A task on the calendar and again in the task pane: one label, and none is skipped.
        let jump = JumpLabels(items: ["event", "task", "other", "task", "last"], alphabet: ["a", "b", "c", "d"])
        #expect(jump.remaining == ["event": "a", "task": "b", "other": "c", "last": "d"])
    }

    @Test func noItemsIsEmpty() {
        #expect(JumpLabels<String>(items: []).isEmpty)
        #expect(!JumpLabels(items: ["one"]).isEmpty)
    }
}

@Suite struct JumpViewportTests {
    /// A time grid at a point a minute, scrolled to show 07:00 to 17:00.
    private let viewport = JumpViewport(top: 420, bottom: 1020)

    @Test func aBlockWhollyOnScreenCarriesItsLabelOnItsTop() {
        #expect(viewport.labelTop(onItemFrom: 540, to: 600, labelHeight: 14) == 540)
        #expect(viewport.labelTop(onItemFrom: 420, to: 1020, labelHeight: 14) == 420)
    }

    @Test func aBlockCutOffAtTheTopCarriesItAtTheTopOfTheViewport() {
        #expect(viewport.labelTop(onItemFrom: 360, to: 480, labelHeight: 14) == 420)
        // All day long: the label still has one place.
        #expect(viewport.labelTop(onItemFrom: 0, to: 1440, labelHeight: 14) == 420)
        // 14 points of it show, which is just enough; 13 are not.
        #expect(viewport.labelTop(onItemFrom: 360, to: 434, labelHeight: 14) == 420)
        #expect(viewport.labelTop(onItemFrom: 360, to: 433, labelHeight: 14) == nil)
    }

    @Test func aBlockCutOffAtTheBottomNeedsRoomForTheLabel() {
        #expect(viewport.labelTop(onItemFrom: 1006, to: 1100, labelHeight: 14) == 1006)
        #expect(viewport.labelTop(onItemFrom: 1007, to: 1100, labelHeight: 14) == nil)
    }

    @Test func aBlockScrolledAwayGetsNone() {
        #expect(viewport.labelTop(onItemFrom: 300, to: 420, labelHeight: 14) == nil)
        #expect(viewport.labelTop(onItemFrom: 1020, to: 1080, labelHeight: 14) == nil)
        #expect(viewport.labelTop(onItemFrom: 1200, to: 1260, labelHeight: 14) == nil)
    }

    @Test func aBlockShorterThanTheLabelHasToShowWhole() {
        #expect(viewport.labelTop(onItemFrom: 500, to: 510, labelHeight: 14) == 500)
        #expect(viewport.labelTop(onItemFrom: 415, to: 425, labelHeight: 14) == nil)
        #expect(viewport.labelTop(onItemFrom: 1011, to: 1021, labelHeight: 14) == nil)
    }

    @Test func aLabelWithOnePlaceHasToBeAllOnScreen() {
        #expect(viewport.shows(top: 420, bottom: 440))
        #expect(!viewport.shows(top: 419, bottom: 439))
        #expect(viewport.shows(top: 1000, bottom: 1020))
        #expect(!viewport.shows(top: 1001, bottom: 1021))
        #expect(!viewport.shows(top: 100, bottom: 120))
    }
}
