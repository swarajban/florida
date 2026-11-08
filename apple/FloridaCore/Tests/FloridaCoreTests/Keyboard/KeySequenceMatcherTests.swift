import Foundation
import Testing
@testable import FloridaCore

@Suite struct KeySequenceMatcherTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func singleChordMatchesImmediately() {
        var matcher = KeySequenceMatcher(keymap: .default)
        #expect(matcher.feed(KeyChord("j"), at: t0) == .matched(.focusNext))
        #expect(matcher.pendingSequence.isEmpty)
        #expect(matcher.feed(KeyChord("k", [.command]), at: t0) == .matched(.commandPalette))
        #expect(matcher.feed(KeyChord("escape"), at: t0) == .matched(.cancel))
    }

    @Test func modifiersDistinguishBindings() {
        var matcher = KeySequenceMatcher(keymap: .default)
        #expect(matcher.feed(KeyChord("h"), at: t0) == .matched(.previousDay))
        #expect(matcher.feed(KeyChord("h", [.shift]), at: t0) == .matched(.previousWeek))
        #expect(matcher.feed(KeyChord("c"), at: t0) == .matched(.newTask))
        #expect(matcher.feed(KeyChord("c", [.shift]), at: t0) == .matched(.newEvent))
        #expect(matcher.feed(KeyChord("c", [.command, .shift]), at: t0) == .matched(.copyLink))
    }

    @Test func twoChordSequenceResolves() {
        var matcher = KeySequenceMatcher(keymap: .default)
        let first = matcher.feed(KeyChord("g"), at: t0)
        guard case .pending(let candidates) = first else {
            Issue.record("expected pending, got \(first)")
            return
        }
        #expect(Set(candidates.map(\.command)) == [.goToDate, .goToTasks, .goToCalendar])
        #expect(matcher.pendingSequence == [KeyChord("g")])

        #expect(matcher.feed(KeyChord("t"), at: t0.addingTimeInterval(0.3)) == .matched(.goToTasks))
        #expect(matcher.pendingSequence.isEmpty)

        #expect(matcher.feed(KeyChord("g"), at: t0.addingTimeInterval(1)) == first)
        #expect(matcher.feed(KeyChord("d"), at: t0.addingTimeInterval(1.2)) == .matched(.goToDate))
        #expect(matcher.feed(KeyChord("g"), at: t0.addingTimeInterval(2)) == first)
        #expect(matcher.feed(KeyChord("c"), at: t0.addingTimeInterval(2.2)) == .matched(.goToCalendar))
    }

    @Test func unknownContinuationIsUnmatchedAndResets() {
        var matcher = KeySequenceMatcher(keymap: .default)
        guard case .pending = matcher.feed(KeyChord("g"), at: t0) else {
            Issue.record("expected pending")
            return
        }
        #expect(matcher.feed(KeyChord("z"), at: t0.addingTimeInterval(0.2)) == .unmatched)
        #expect(matcher.pendingSequence.isEmpty)
        // "g" then "j": the second chord is not re-interpreted as a fresh `j` binding.
        _ = matcher.feed(KeyChord("g"), at: t0.addingTimeInterval(1))
        #expect(matcher.feed(KeyChord("j"), at: t0.addingTimeInterval(1.1)) == .unmatched)
        // ...but the next press starts clean.
        #expect(matcher.feed(KeyChord("j"), at: t0.addingTimeInterval(1.2)) == .matched(.focusNext))
    }

    @Test func unknownChordIsUnmatched() {
        var matcher = KeySequenceMatcher(keymap: .default)
        #expect(matcher.feed(KeyChord("z", [.command]), at: t0) == .unmatched)
        #expect(matcher.feed(KeyChord("q"), at: t0) == .unmatched)
        #expect(matcher.pendingSequence.isEmpty)
    }

    @Test func timeoutDiscardsPendingPrefix() {
        var matcher = KeySequenceMatcher(keymap: .default, timeout: 1.0)
        _ = matcher.feed(KeyChord("g"), at: t0)
        // After the timeout "d" is a fresh press: the day view, not go-to-date.
        #expect(matcher.feed(KeyChord("d"), at: t0.addingTimeInterval(1.5)) == .matched(.viewDay))
        #expect(matcher.pendingSequence.isEmpty)

        // Exactly at the timeout the sequence is still alive.
        _ = matcher.feed(KeyChord("g"), at: t0.addingTimeInterval(10))
        #expect(matcher.feed(KeyChord("d"), at: t0.addingTimeInterval(11)) == .matched(.goToDate))

        // A stale "g" followed by an unknown chord after the timeout is plain unmatched.
        _ = matcher.feed(KeyChord("g"), at: t0.addingTimeInterval(20))
        #expect(matcher.feed(KeyChord("z"), at: t0.addingTimeInterval(25)) == .unmatched)
    }

    @Test func customTimeout() {
        var matcher = KeySequenceMatcher(keymap: .default, timeout: 0.2)
        _ = matcher.feed(KeyChord("g"), at: t0)
        #expect(matcher.feed(KeyChord("t"), at: t0.addingTimeInterval(0.5)) == .matched(.today))
    }

    @Test func resetClearsPendingSequence() {
        var matcher = KeySequenceMatcher(keymap: .default)
        _ = matcher.feed(KeyChord("g"), at: t0)
        #expect(!matcher.pendingSequence.isEmpty)
        matcher.reset()
        #expect(matcher.pendingSequence.isEmpty)
        #expect(matcher.feed(KeyChord("d"), at: t0.addingTimeInterval(0.1)) == .matched(.viewDay))
    }

    @Test func threeChordSequencesWork() throws {
        let keymap = try Keymap(validating: [
            try #require(KeyBinding("g g d", .goToDate)),
            try #require(KeyBinding("g g t", .goToTasks)),
            try #require(KeyBinding("j", .focusNext)),
        ])
        var matcher = KeySequenceMatcher(keymap: keymap)
        #expect(matcher.feed(KeyChord("g"), at: t0) == .pending(keymap.bindings.filter { $0.command != .focusNext }))
        #expect(matcher.feed(KeyChord("g"), at: t0.addingTimeInterval(0.5)) == .pending(keymap.bindings.filter { $0.command != .focusNext }))
        #expect(matcher.pendingSequence == [KeyChord("g"), KeyChord("g")])
        #expect(matcher.feed(KeyChord("t"), at: t0.addingTimeInterval(1.0)) == .matched(.goToTasks))
    }
}
