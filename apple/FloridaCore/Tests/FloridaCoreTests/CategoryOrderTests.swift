import Foundation
import Testing
@testable import FloridaCore

@Suite struct CategoryOrderTests {
    static let at = Date(timeIntervalSince1970: 1_794_000_000)

    static func category(_ id: String, _ name: String, _ area: CategoryArea?, sortOrder: Int = 0) -> TaskCategory {
        TaskCategory(id: id, name: name, area: area, scheduleId: "work", sortOrder: sortOrder, createdAt: at, updatedAt: at)
    }

    @Test func inboxThenWorkThenPersonalEachByName() {
        // Stored in an order that agrees with the listed one nowhere: by name alone "Finance"
        // leads, by `sortOrder` alone "Home" does.
        let categories = [
            Self.category("home", "Home", .personal, sortOrder: 0),
            Self.category("infosec", "Infosec", .work, sortOrder: 1),
            Self.category("finance", "Finance", .personal, sortOrder: 2),
            Self.category("inbox", "Inbox", nil, sortOrder: 9),
            Self.category("eng", "Engineering", .work, sortOrder: 4),
        ]
        #expect(categories.inListOrder().map(\.name) == ["Inbox", "Engineering", "Infosec", "Finance", "Home"])
    }

    @Test func namesSortWithoutRegardToCase() {
        // Byte order puts every capital before every small letter: "Zoo" before "admin".
        let categories = [
            Self.category("z", "Zoo", .work),
            Self.category("a", "admin", .work),
            Self.category("m", "Mail", .work),
        ]
        #expect(categories.inListOrder().map(\.name) == ["admin", "Mail", "Zoo"])
    }

    @Test func aCategoryWithoutAnAreaComesAfterPersonal() {
        // Only the category with the inbox id is the inbox: another one named "Inbox" or with no
        // area is an ordinary category that has not been given an area yet.
        let categories = [
            Self.category("old", "Archive", nil),
            Self.category("p", "Zen", .personal),
            Self.category("w", "Work", .work),
            Self.category("inbox", "Inbox", nil),
        ]
        #expect(categories.inListOrder().map(\.id) == ["inbox", "w", "p", "old"])
    }

    @Test func equalNamesFallBackToTheId() {
        let first = [Self.category("b", "Ops", .work), Self.category("a", "ops", .work)]
        #expect(first.inListOrder().map(\.id) == ["a", "b"])
        #expect(first.reversed().inListOrder().map(\.id) == ["a", "b"])
    }
}
