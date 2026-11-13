import FloridaKit
import Foundation
import Testing
#if canImport(FloridaWidgetLogic)
@testable import FloridaWidgetLogic
#endif

struct WidgetIntegrityTests {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return result
    }

    private func instant(_ text: String) -> Date { JSONCoding.parseInstant(text)! }

    private func task(_ id: String = "task", due: String? = nil) -> TaskItem {
        TaskItem(id: id, categoryId: "work", title: id, durationMinutes: 30,
                 deadlineType: .soft, dueAt: due.map(instant), createdAt: .distantPast, updatedAt: .distantPast)
    }

    @Test func unavailableStoreRetriesLaterRatherThanImmediately() {
        let now = instant("2026-11-02T07:50:00Z")
        #expect(WidgetTaskTimeline.reloadDate(at: now, from: nil) == now.addingTimeInterval(30 * 60))
        let loaded = WidgetTaskTimeline(tasks: [], categories: [], placements: [:], calendar: calendar)
        #expect(WidgetTaskTimeline.reloadDate(at: now, from: loaded) == instant("2026-11-02T08:00:00Z"))
    }

    @Test func sqliteProjectionCarriesTheSettingsZoneIntoItsSnapshot() throws {
        let database = try AppDatabase.inMemory()
        let now = instant("2026-11-02T07:50:00Z")
        try database.apply(SyncResponse(
            cursor: "ready", settings: UserSettings(id: "settings", timeZone: "America/Los_Angeles", updatedAt: now),
            tasks: [task(due: "2026-11-02T07:55:00Z")]))
        let loaded = try #require(WidgetStore.taskTimeline(from: database))
        #expect(loaded.calendar.timeZone.identifier == "America/Los_Angeles")
        #expect(loaded.dates(at: now).last == instant("2026-11-02T08:00:00Z"))
        let projected = try #require(WidgetStore.openTasks(limit: 5, at: now, from: database))
        #expect(projected.count == 1)
        #expect(!projected.tasks[0].late)
    }

    @Test func unplacedOverdueTaskIsLate() {
        let item = task(due: "2020-01-01T00:00:00Z")
        #expect(WidgetTask(task: item, placements: [], category: nil).late)
    }

    @Test func latenessUsesTheEntryTimeAndRespectsDisabledDeadlines() throws {
        var due = task(due: "2026-11-02T07:55:00Z")
        let before = instant("2026-11-02T07:50:00Z")
        let snapshot = WidgetTaskTimeline(tasks: [due], categories: [], placements: [:], calendar: calendar)
        #expect(try #require(snapshot.rows(limit: 5, at: before).first).late == false)
        #expect(!TaskTiming(task: due, now: due.dueAt!).isOverdue)
        #expect(try #require(snapshot.rows(limit: 5, at: due.dueAt!).first).late)
        due.deadlineType = .none
        #expect(!WidgetTask(task: due, placements: [], category: nil, at: instant("2027-01-01T00:00:00Z")).late)
        let placement = Placement(id: "piece", taskId: due.id, startAt: before,
                                  endAt: instant("2026-11-02T08:00:00Z"), pinned: false, computedAt: before)
        #expect(!WidgetTask(task: due, placements: [placement], category: nil, at: before).late)
        due.deadlineType = .hard
        #expect(WidgetTask(task: due, placements: [placement], category: nil, at: before).late)
        due.completedAt = before
        #expect(!WidgetTask(task: due, placements: [placement], category: nil, at: due.dueAt!).late)
    }

    @Test func timelineIncludesDueTransitionsAndSettingsZoneMidnight() {
        let now = instant("2026-11-02T07:50:00Z")
        let due = task(due: "2026-11-02T07:55:00Z")
        let snapshot = WidgetTaskTimeline(tasks: [due], categories: [], placements: [:], calendar: calendar)
        #expect(snapshot.dates(at: now).contains(instant("2026-11-02T07:55:00Z")))
        #expect(snapshot.dates(at: now).contains(instant("2026-11-02T08:00:00Z")))
        let dstMorning = instant("2026-11-01T07:00:00Z")
        #expect(snapshot.dates(at: dstMorning).last == instant("2026-11-02T08:00:00Z"))
        #expect(snapshot.dates(at: now) == snapshot.dates(at: now).sorted())
        #expect(WidgetFormatting.dayLabel(instant("2026-11-02T18:00:00Z"), now: now, calendar: calendar) == "Tomorrow")
        #expect(WidgetFormatting.dayLabel(instant("2026-11-02T18:00:00Z"), now: instant("2026-11-02T08:00:00Z"), calendar: calendar) == "Today")
    }

    @Test func nextMidnightAfterASkippedMidnightUsesStartOfNextDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Havana")!
        let snapshot = WidgetTaskTimeline(tasks: [], categories: [], placements: [:], calendar: calendar)
        let now = instant("2026-03-08T17:00:00Z")
        let midnight = instant("2026-03-09T04:00:00Z")
        #expect(snapshot.dates(at: now).last == midnight)
        #expect(WidgetTaskTimeline.reloadDate(at: instant("2026-03-09T03:50:00Z"), from: snapshot) == midnight)
    }

    @Test func distantDatesAreFormattedInSettingsZone() {
        let now = instant("2026-10-01T12:00:00Z")
        let date = instant("2026-11-17T07:00:00Z")
        var format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        format.timeZone = calendar.timeZone
        let expected = date.formatted(format)
        #expect(WidgetFormatting.dayLabel(date, now: now, calendar: calendar) == expected)
        let weekdayDate = instant("2026-10-04T06:00:00Z")
        var weekdayFormat = Date.FormatStyle.dateTime.weekday(.abbreviated)
        weekdayFormat.timeZone = calendar.timeZone
        let weekday = weekdayDate.formatted(weekdayFormat)
        #expect(WidgetFormatting.dayLabel(weekdayDate, now: now, calendar: calendar) == weekday)
    }

    @Test func missingStoreFailureCanRecoverInSameReader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let reader = WidgetDatabaseReader(url: url)
        #expect(throws: (any Error).self) { try reader.open() }
        let host = try AppDatabase(path: url.path)
        try host.apply(SyncResponse(cursor: "first-sync"))
        #expect(try reader.open().cursor() == "first-sync")
    }

    @Test func transientOpenFailureIsNotMemoized() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let reader = WidgetDatabaseReader(url: url)
        #expect(throws: (any Error).self) { try reader.open() }
        try FileManager.default.removeItem(at: directory)
        let host = try AppDatabase(path: url.path)
        try host.apply(SyncResponse(cursor: "recovered"))
        #expect(try reader.open().cursor() == "recovered")
    }
}
