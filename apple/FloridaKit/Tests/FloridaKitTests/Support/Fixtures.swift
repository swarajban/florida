import Foundation
@testable import FloridaKit

/// Model values with sensible defaults, so tests only spell out what they care about.
enum Fixtures {
    static let t0 = instant("2026-11-08T00:00:00Z")

    /// A range wide enough to contain every fixture date.
    static let allTime = instant("2020-01-01T00:00:00Z")..<instant("2030-01-01T00:00:00Z")

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func instant(_ iso: String) -> Date {
        guard let date = JSONCoding.parseInstant(iso) else { fatalError("bad fixture instant \(iso)") }
        return date
    }

    static func schedule(
        id: String = "work",
        windows: [ScheduleWindow] = [ScheduleWindow(days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00")]
    ) -> Schedule {
        Schedule(id: id, name: id.capitalized, timeZone: "America/Los_Angeles", windows: windows, createdAt: t0, updatedAt: t0)
    }

    static func category(id: String = "inbox", scheduleId: String = "work", sortOrder: Int = 0) -> Category {
        Category(id: id, name: id.capitalized, scheduleId: scheduleId, sortOrder: sortOrder, createdAt: t0, updatedAt: t0)
    }

    static func task(
        id: String, categoryId: String = "inbox", title: String? = nil, priority: Priority = .medium,
        dueAt: Date? = nil, completedAt: Date? = nil, createdAt: Date = t0, deletedAt: Date? = nil
    ) -> TaskItem {
        TaskItem(
            id: id, categoryId: categoryId, title: title ?? id, durationMinutes: 60, priority: priority,
            deadlineType: dueAt == nil ? .none : .soft, dueAt: dueAt, completedAt: completedAt,
            createdAt: createdAt, updatedAt: createdAt, deletedAt: deletedAt)
    }

    static func placement(id: String, taskId: String, start: String, end: String) -> Placement {
        Placement(id: id, taskId: taskId, startAt: instant(start), endAt: instant(end), pinned: false, computedAt: t0)
    }

    static func account(id: String = "acct") -> GoogleAccount {
        GoogleAccount(id: id, email: "\(id)@example.com", label: id, updatedAt: t0)
    }

    static func calendar(id: String = "cal", accountId: String = "acct", selected: Bool = true) -> CalendarInfo {
        CalendarInfo(id: id, accountId: accountId, googleId: "g-\(id)", summary: id, accessRole: "owner", selected: selected, updatedAt: t0)
    }

    static func event(
        id: String, calendarId: String = "cal", start: String, end: String, allDay: Bool = false,
        status: String = "confirmed", responseStatus: String? = "accepted", deletedAt: Date? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, calendarId: calendarId, googleId: "g-\(id)", status: status, summary: id,
            startAt: instant(start), endAt: instant(end), allDay: allDay, responseStatus: responseStatus,
            updatedAt: t0, deletedAt: deletedAt)
    }

    static func piece(taskId: String, start: String, end: String) -> SchedulingResult.Piece {
        SchedulingResult.Piece(taskId: taskId, start: instant(start), end: instant(end), pinned: false)
    }

    // MARK: Response bodies the server would send

    /// `{<key>: <record>, "scheduling": <scheduling>}`, i.e. a `TaskWriteResponse` / `CategoryWriteResponse` /
    /// `ScheduleWriteResponse`. Built through JSONSerialization because those types have no public initializer.
    static func putResponse(_ key: String, _ record: some Encodable, scheduling: SchedulingResult = SchedulingResult()) throws -> Data {
        let recordJSON = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(record))
        let schedulingJSON = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(scheduling))
        return try JSONSerialization.data(withJSONObject: [key: recordJSON, "scheduling": schedulingJSON])
    }

    /// `{"scheduling": <scheduling>}`, the body of every `DELETE /api/...`.
    static func deleteResponse(scheduling: SchedulingResult = SchedulingResult()) throws -> Data {
        let schedulingJSON = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(scheduling))
        return try JSONSerialization.data(withJSONObject: ["scheduling": schedulingJSON])
    }
}
