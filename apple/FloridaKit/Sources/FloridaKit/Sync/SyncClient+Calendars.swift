import Foundation

/// Body of `PATCH /api/calendars/:id`.
struct CalendarPatch: Encodable {
    var selected: Bool? = nil
    var blocksScheduling: Bool? = nil
}

extension SyncClient {
    /// `PATCH /api/calendars/:id` with `{selected}`: shows or hides a Google calendar's events.
    /// On success stores the flag locally and applies the scheduler result the server returns.
    /// The caller may set the local flag beforehand with `AppDatabase.setCalendarSelected` so the
    /// UI does not wait on the network; the next pull replaces the calendar table either way.
    public func setCalendarSelected(id: String, selected: Bool) async throws {
        let body = try JSONCoding.encoder.encode(CalendarPatch(selected: selected))
        let request = api.makeRequest(method: "PATCH", path: "api/calendars", id: id, body: body)
        let response: SchedulingResponse = try await api.perform(request)
        try database.setCalendarSelected(id: id, selected: selected)
        try database.apply(response.scheduling, computedAt: Date())
    }

    public func setCalendarBlocksScheduling(id: String, blocksScheduling: Bool) async throws {
        let body = try JSONCoding.encoder.encode(CalendarPatch(blocksScheduling: blocksScheduling))
        let request = api.makeRequest(method: "PATCH", path: "api/calendars", id: id, body: body)
        let response: SchedulingResponse = try await api.perform(request)
        try database.setCalendarBlocksScheduling(id: id, blocksScheduling: blocksScheduling)
        try database.apply(response.scheduling, computedAt: Date())
    }
}
