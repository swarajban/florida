import FloridaKit
import Foundation

enum WidgetStore {
    private static let reader = WidgetDatabaseReader(url: AppDatabase.sharedURL())
    static var database: AppDatabase? { try? reader.open() }
    static let calendar = Calendar.autoupdatingCurrent

    /// Why the store cannot be read, in a few words; nil when it opened.
    static var unavailableReason: String? {
        do { _ = try reader.open(); return nil }
        catch { return error.localizedDescription }
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

    static func openTasks(
        limit: Int, at date: Date, from database: AppDatabase? = WidgetStore.database
    ) -> (count: Int, tasks: [WidgetTask])? {
        guard let loaded = taskTimeline(from: database) else { return nil }
        return (loaded.tasks.count, loaded.rows(limit: limit, at: date))
    }

    static func taskTimeline(from database: AppDatabase? = WidgetStore.database) -> WidgetTaskTimeline? {
        guard let database else { return nil }
        do {
            let categories = try database.categories()
            let tasks = try database.openTasks()
            var calendar = Self.calendar
            if let identifier = try database.userSettings()?.timeZone, let timeZone = TimeZone(identifier: identifier) {
                calendar.timeZone = timeZone
            }
            let placements = try database.placementsByTask()
            return WidgetTaskTimeline(tasks: tasks, categories: categories, placements: placements, calendar: calendar)
        } catch {
            return nil
        }
    }

    private static func categoriesById(_ database: AppDatabase) throws -> [String: TaskCategory] {
        Dictionary(uniqueKeysWithValues: try database.categories().map { ($0.id, $0) })
    }
}
