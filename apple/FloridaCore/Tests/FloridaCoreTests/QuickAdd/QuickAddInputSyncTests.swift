import Testing
@testable import FloridaCore

@Suite struct QuickAddInputSyncTests {
    @Test func ordinaryRendersNeverReplaceLiveInput() {
        var sync = QuickAddInputSync(revision: 0)
        var nativeText = "famalooda"
        if sync.takeEdit(revision: 0, hasMarkedText: true) { nativeText = "" }
        if sync.takeEdit(revision: 0, hasMarkedText: false) { nativeText = "" }
        nativeText += " secret Santa"
        if sync.takeEdit(revision: 0, hasMarkedText: false) { nativeText = "famalooda" }
        #expect(nativeText == "famalooda secret Santa")
    }

    @Test func explicitEditWaitsForCompositionAndAppliesOnce() {
        var sync = QuickAddInputSync(revision: 0)
        let appliedWhileComposing = sync.takeEdit(revision: 1, hasMarkedText: true)
        #expect(!appliedWhileComposing)
        #expect(sync.appliedRevision == 0)
        let appliedAfterCommit = sync.takeEdit(revision: 1, hasMarkedText: false)
        #expect(appliedAfterCommit)
        #expect(sync.appliedRevision == 1)
        let appliedAgain = sync.takeEdit(revision: 1, hasMarkedText: false)
        let appliedOlder = sync.takeEdit(revision: 0, hasMarkedText: false)
        let appliedNewer = sync.takeEdit(revision: 2, hasMarkedText: false)
        #expect(!appliedAgain)
        #expect(!appliedOlder)
        #expect(appliedNewer)
    }

    @Test func remountDoesNotReplayTheLastEdit() {
        var sync = QuickAddInputSync(revision: 4)
        let appliedSeed = sync.takeEdit(revision: 4, hasMarkedText: false)
        let appliedNewer = sync.takeEdit(revision: 5, hasMarkedText: false)
        #expect(!appliedSeed)
        #expect(appliedNewer)
    }
}
