import FloridaKit
import Foundation

struct WidgetDatabaseReader {
    private struct NoAppGroupContainer: LocalizedError {
        var errorDescription: String? { "No shared App Group container" }
    }

    let url: URL?

    init(url: URL?) {
        self.url = url
    }

    func open() throws -> AppDatabase {
        guard let url else { throw NoAppGroupContainer() }
        return try AppDatabase.openExisting(path: url.path(percentEncoded: false))
    }
}
