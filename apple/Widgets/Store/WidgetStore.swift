import FloridaKit
import Foundation

/// Read-only access to the shared store for the timeline providers. The database is opened once
/// per extension process; every loader returns nil when it cannot be opened or read, and the
/// views show a placeholder for nil (with `unavailableReason` so a blank widget can be diagnosed
/// from the Home Screen).
enum WidgetStore {
    /// The extension has no App Group container (entitlement missing or a different group id):
    /// `AppDatabase.defaultURL()` would open an empty private store and the widget would look
    /// merely empty, so refuse instead and say why.
    private struct NoAppGroupContainer: LocalizedError {
        var errorDescription: String? { "No shared App Group container" }
    }

    private static let opened: Result<AppDatabase, any Error> = Result {
        guard let url = AppDatabase.sharedURL() else { throw NoAppGroupContainer() }
        return try AppDatabase(path: url.path(percentEncoded: false))
    }
    static var database: AppDatabase? { try? opened.get() }
    static let calendar = Calendar.autoupdatingCurrent

    /// Why the store cannot be read, in a few words; nil when it opened.
    static var unavailableReason: String? {
        if case .failure(let error) = opened {
            return error.localizedDescription
        }
        return nil
    }

    /// Timed events and task blocks overlapping `range`, by start. All-day events are left out
    /// because they have no meaningful "next" time.
    static func timedBlocks(in range: Range<Date>) -> [WidgetBlock]? {
        guard let database else { return nil }
        do {
            let categories = try categoriesById(database)
            let events = try database.events(in: range, calendar: calendar)
                .filter { !$0.allDay }
                .map(WidgetBlock.init(event:))
            let blocks = try database.scheduledBlocks(in: range)
                .map { WidgetBlock(block: $0, category: categories[$0.task.categoryId]) }
            return (events + blocks).sorted(by: WidgetBlock.byStart)
        } catch {
            return nil
        }
    }

    /// Everything on the calendar day containing `day`: all-day events first, then timed events
    /// and task blocks by start.
    static func agenda(for day: Date) -> [WidgetBlock]? {
        guard let database else { return nil }
        do {
            let categories = try categoriesById(database)
            let agenda = try database.agenda(for: day, calendar: calendar)
            let events = agenda.events.map(WidgetBlock.init(event:))
            let blocks = agenda.placements.map { WidgetBlock(block: $0, category: categories[$0.task.categoryId]) }
            return (events + blocks).sorted(by: WidgetBlock.byStart)
        } catch {
            return nil
        }
    }

    /// Open tasks in `openTasks()` order with their late flag, plus the total count.
    static func openTasks(limit: Int) -> (count: Int, tasks: [WidgetTask])? {
        guard let database else { return nil }
        do {
            let categories = try categoriesById(database)
            let tasks = try database.openTasks()
            let placements = try database.placementsByTask()
            let rows = tasks.prefix(limit).map { task in
                WidgetTask(task: task, placements: placements[task.id] ?? [], category: categories[task.categoryId])
            }
            return (tasks.count, rows)
        } catch {
            return nil
        }
    }

    private static func categoriesById(_ database: AppDatabase) throws -> [String: TaskCategory] {
        Dictionary(uniqueKeysWithValues: try database.categories().map { ($0.id, $0) })
    }
}
