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

    @Test func filteredSubsetUsesAreaOrder() {
        let categories = [
            Self.category("none", "work archive", nil, sortOrder: -10),
            Self.category("personal", "Work", .personal, sortOrder: -20),
            Self.category("work", "Team work", .work, sortOrder: 50),
            Self.category("inbox", "Inbox", .personal, sortOrder: 100),
        ]
        let matches = categories.filter { $0.name.lowercased().contains("work") }
        #expect(matches.inListOrder().map(\.id) == ["work", "personal", "none"])
        #expect(categories.inListOrder().first?.isInbox == true)
    }

    @Test func renamingAndAssigningAreasRecomputesTheOrder() {
        var categories = [
            Self.category("inbox", "Inbox", nil),
            Self.category("engineering", "Engineering", .work),
            Self.category("deals", "Deals", .work),
            Self.category("personal", "Finances & accounts", .personal),
            Self.category("legacy-z", "Zoo", nil),
            Self.category("legacy-a", "admin", nil),
        ]
        #expect(categories.inListOrder().map(\.id) == ["inbox", "deals", "engineering", "personal", "legacy-a", "legacy-z"])
        categories[4].area = .work
        categories[4].name = "accounting"
        categories[2].area = .personal
        #expect(categories.inListOrder().map(\.id) == ["inbox", "legacy-z", "engineering", "deals", "personal", "legacy-a"])
    }
}
