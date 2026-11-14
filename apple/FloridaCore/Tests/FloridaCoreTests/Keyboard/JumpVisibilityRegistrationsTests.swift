import Foundation
import Testing
@testable import FloridaCore

@Suite struct JumpVisibilityRegistrationsTests {
    @Test func onlyVisibleRegistrationsConsumeAnItem() {
        var visibility = JumpVisibilityRegistrations<String>()
        let owner = UUID()
        visibility.set("a", owner: owner, visible: false)
        #expect(visibility.items.isEmpty)
        visibility.set("a", owner: owner, visible: true)
        visibility.set("a", owner: owner, visible: true)
        #expect(visibility.items == ["a"])
        visibility.set("a", owner: owner, visible: false)
        #expect(visibility.items.isEmpty)
    }

    @Test func anOldRowCannotRemoveItsVisibleReplacement() {
        var visibility = JumpVisibilityRegistrations<String>()
        let old = UUID()
        let replacement = UUID()
        visibility.set("a", owner: old, visible: true)
        visibility.set("a", owner: replacement, visible: true)
        visibility.set("a", owner: old, visible: false)
        #expect(visibility.items == ["a"])
        visibility.set("a", owner: replacement, visible: false)
        #expect(visibility.items.isEmpty)
    }

    @Test func eachItemKeepsItsOwnOwners() {
        var visibility = JumpVisibilityRegistrations<String>()
        let owner = UUID()
        visibility.set("a", owner: owner, visible: true)
        visibility.set("b", owner: owner, visible: true)
        visibility.set("a", owner: owner, visible: false)
        #expect(visibility.items == ["b"])
    }
}
