import Foundation
import Testing
@testable import FloridaKit

@Suite struct CategoryListOrderTests {
    @Test func appReadsAndObservationsShareTheCoreOrder() async throws {
        let db = try AppDatabase.inMemory()
        let categories = [
            TaskCategory(id: "personal", name: "Accounts", area: .personal, scheduleId: "work", sortOrder: -20, createdAt: Fixtures.t0, updatedAt: Fixtures.t0),
            TaskCategory(id: "z", name: "Zoo", area: .work, scheduleId: "work", sortOrder: -10, createdAt: Fixtures.t0, updatedAt: Fixtures.t0),
            TaskCategory(id: "a", name: "admin", area: .work, scheduleId: "work", sortOrder: 50, createdAt: Fixtures.t0, updatedAt: Fixtures.t0),
            TaskCategory(id: "legacy", name: "Archive", scheduleId: "work", sortOrder: -30, createdAt: Fixtures.t0, updatedAt: Fixtures.t0),
            Fixtures.category(sortOrder: 100),
        ]
        try db.apply(SyncResponse(cursor: "c1", categories: categories))
        var observation = db.observeCategories().makeAsyncIterator()
        let expected = ["inbox", "a", "z", "personal", "legacy"]
        #expect(try db.categories().map(\.id) == expected)
        #expect(try await observation.next()?.map(\.id) == expected)

        var reassigned = categories[3]
        reassigned.area = .work
        try db.saveCategory(reassigned, now: Fixtures.t0.addingTimeInterval(1))
        let afterAreaChange = ["inbox", "a", "legacy", "z", "personal"]
        #expect(try db.categories().map(\.id) == afterAreaChange)
        #expect(try await observation.next()?.map(\.id) == afterAreaChange)

        reassigned.name = "aardvark"
        try db.saveCategory(reassigned, now: Fixtures.t0.addingTimeInterval(2))
        let afterRename = ["inbox", "legacy", "a", "z", "personal"]
        #expect(try db.categories().map(\.id) == afterRename)
        #expect(try await observation.next()?.map(\.id) == afterRename)

        try db.deleteCategory(id: "legacy", now: Fixtures.t0.addingTimeInterval(3))
        #expect(try db.categories().map(\.id) == expected.filter { $0 != "legacy" })
        #expect(try await observation.next()?.map(\.id) == expected.filter { $0 != "legacy" })
    }
}
