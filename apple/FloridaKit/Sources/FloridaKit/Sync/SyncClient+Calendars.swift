import Foundation

/// Body of `PATCH /api/calendars/:id`.
struct CalendarPatch: Encodable {
    var selected: Bool? = nil
    var blocksScheduling: Bool? = nil
}

extension SyncClient {
    /// `PATCH /api/calendars/:id` with `{selected}`: shows or hides a Google calendar's events.
    /// On success stores the flag locally and applies the scheduler result the server returns.
    /// Apps use the store's queued setters for local-first toggles. This direct request never
    /// overwrites a newer queued flag.
    public func setCalendarSelected(id: String, selected: Bool) async throws {
        let body = try JSONCoding.encoder.encode(CalendarPatch(selected: selected))
        let request = api.makeRequest(method: "PATCH", path: "api/calendars", id: id, body: body)
        let response: SchedulingResponse = try await api.perform(request)
        try database.acceptCalendarPatch(id: id, patch: CalendarPatch(selected: selected), scheduling: response.scheduling)
    }

    public func setCalendarBlocksScheduling(id: String, blocksScheduling: Bool) async throws {
        let body = try JSONCoding.encoder.encode(CalendarPatch(blocksScheduling: blocksScheduling))
        let request = api.makeRequest(method: "PATCH", path: "api/calendars", id: id, body: body)
        let response: SchedulingResponse = try await api.perform(request)
        try database.acceptCalendarPatch(id: id, patch: CalendarPatch(blocksScheduling: blocksScheduling), scheduling: response.scheduling)
    }
}
