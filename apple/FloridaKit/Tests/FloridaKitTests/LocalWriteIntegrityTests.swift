import Foundation
import GRDB
import Testing
@testable import FloridaKit

@Suite struct LocalWriteIntegrityTests {
    func body(_ write: PendingWrite) throws -> [String: Any] {
        let data = try #require(write.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func dayOnlyDateEntryStoresTheServerSettingsZoneInstant() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "settings", settings: UserSettings(
            id: "default", timeZone: "America/Los_Angeles", updatedAt: Fixtures.t0)))
        let settings = try #require(try db.userSettings())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: settings.timeZone))
        let now = try #require(JSONCoding.parseInstant("2026-11-13T17:00:00Z"))
        let entry = DateEntry.parse("nov 17 2026", now: now, calendar: calendar)
        guard case .date(let day, let hasTime) = entry else {
            Issue.record("Expected a day-only date entry")
            return
        }
        #expect(!hasTime)
        var task = Fixtures.task(id: "day-only")
        task.deadlineType = .soft
        task.dueAt = TaskDay.due(on: day, calendar: calendar)
        let mutation = try db.saveTask(task, original: nil)
        let expected = try #require(JSONCoding.parseInstant("2026-11-17T17:00:00-08:00"))
        #expect(expected == JSONCoding.parseInstant("2026-11-18T01:00:00Z"))
        #expect(mutation.after.dueAt == expected)
        let stored = try #require(try db.task(id: task.id))
        #expect(stored.dueAt == expected)
        #expect(!TaskDay.dueHasTime(try #require(stored.dueAt), calendar: calendar))
        let write = try #require(try db.pendingWrites().first)
        let dueAt = try #require(try body(write)["dueAt"] as? String)
        #expect(JSONCoding.parseInstant(dueAt) == expected)
    }

    @Test(arguments: [false, true])
    func recurringAcceptanceAdvancesNewerEditBaselineWithoutClobberingIt(_ existing: Bool) throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "recurring")
        task.recurrence = TaskRecurrence(frequency: .week, interval: 1, timeZone: "UTC", startDate: "2026-11-08")
        if existing {
            task.recurrenceSeriesId = "series"
            task.recurrenceDate = "2026-11-08"
            task.recurrenceRevision = "r1"
            try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        }
        task.title = "First edit"
        try db.saveTask(task)
        let first = try #require(try db.pendingWrites().first)
        task.notes = "Second edit"
        try db.saveTask(task)
        var accepted = task
        accepted.notes = nil
        accepted.recurrenceRevision = "r2"
        try db.completePendingWrite(first, record: accepted, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
        let newer = try #require(try db.pendingWrites().first)
        #expect(try body(newer)["expectedRecurrenceRevision"] as? String == "r2")
        #expect(try body(newer)["notes"] as? String == "Second edit")
        #expect(newer.op == .patch)
        #expect(try db.task(id: task.id)?.notes == "Second edit")
        #expect(try db.task(id: task.id)?.recurrenceRevision == "r2")
    }

    @Test func rejectedCreationDoesNotLeaveAPatchOnlyPoisonedRow() throws {
        let db = try AppDatabase.inMemory()
        let task = Fixtures.task(id: "new")
        try db.saveTask(task)
        let write = try #require(try db.pendingWrites().first)
        try db.resolveDroppedWrite(write, serverCopy: .missing)
        var repaired = try #require(try db.task(id: task.id))
        repaired.title = "Corrected creation"
        try db.saveTask(repaired)
        #expect(try db.pendingWrites().first?.op == .put)
        let repairedWrite = try #require(try db.pendingWrites().first)
        #expect(try body(repairedWrite)["title"] as? String == repaired.title)
        try db.removePendingWrite(seq: #require(repairedWrite.seq))
        try db.requeue(write)
        #expect(try db.pendingWrites().first?.op == .put)
        #expect(try db.pendingWrites().first?.body == write.body)
    }

    @Test func categoryDeletionReassignsRowsAndQueuedBodiesWithoutTaskPatches() throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        let task = Fixtures.task(id: "t")
        let completed = Fixtures.task(id: "done", categoryId: "work", completedAt: Fixtures.t0)
        let project = Project(id: "p", name: "Project", categoryId: "work", createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        try db.apply(SyncResponse(cursor: "c", categories: [category], tasks: [task, completed], projects: [project]))
        var edited = task
        edited.categoryId = category.id
        edited.notes = "Keep me"
        try db.saveTask(edited)
        try db.saveProject(project)
        try db.deleteCategory(id: category.id)
        #expect(try db.task(id: task.id)?.categoryId == "inbox")
        #expect(try db.task(id: completed.id)?.categoryId == "inbox")
        #expect(try db.project(id: project.id)?.categoryId == nil)
        let queue = try db.pendingWrites()
        #expect(queue.count == 3)
        #expect(!queue.contains { $0.entityId == completed.id })
        #expect(try body(#require(queue.first { $0.entity == .task }))["categoryId"] as? String == "inbox")
        #expect(try body(#require(queue.first { $0.entity == .task }))["notes"] as? String == "Keep me")
        #expect(try body(#require(queue.first { $0.entity == .project }))["categoryId"] is NSNull)
    }

    @Test func pendingCalendarFlagsSurviveAnOverlappingPull() throws {
        let db = try AppDatabase.inMemory()
        let calendar = Fixtures.calendar()
        try db.apply(SyncResponse(cursor: "c", calendars: [calendar]))
        try db.setCalendarSelected(id: calendar.id, selected: false)
        try db.setCalendarBlocksScheduling(id: calendar.id, blocksScheduling: false)
        try db.apply(SyncResponse(cursor: "later", calendars: [calendar]))
        let stored = try #require(try db.calendars().first)
        #expect(!stored.selected && !stored.blocksScheduling)
        let queue = try db.pendingWrites()
        #expect(queue.count == 1)
        let write = try #require(queue.first)
        #expect(write.entity.rawValue == "calendar" && write.op == .patch)
        #expect(try body(write)["selected"] as? Bool == false)
        #expect(try body(write)["blocksScheduling"] as? Bool == false)
    }

    func series(_ id: String, day: String) -> CalendarEvent {
        var event = Fixtures.event(id: id, start: "2026-11-\(day)T10:00:00Z", end: "2026-11-\(day)T11:00:00Z")
        event.recurringEventId = "series"
        return event
    }

    @Test(arguments: ["delete", "edit", "discard"])
    func replacingSeriesMoveRestoresUnqueuedSiblings(_ replacement: String) throws {
        let db = try AppDatabase.inMemory()
        let anchor = series("e1", day: "09")
        let sibling = series("e2", day: "10")
        try db.apply(SyncResponse(cursor: "c", events: [anchor, sibling]))
        try db.moveEventSeries(instanceId: anchor.id, start: anchor.startAt!.addingTimeInterval(3600), end: anchor.endAt!.addingTimeInterval(3600))
        let move = try #require(try db.pendingWrites().first)
        if replacement == "delete" {
            try db.deleteEvent(id: anchor.id)
        } else if replacement == "edit" {
            var edited = try #require(try db.event(id: anchor.id))
            edited.startAt = edited.startAt?.addingTimeInterval(3600)
            edited.endAt = edited.endAt?.addingTimeInterval(3600)
            try db.saveEvent(edited)
        } else {
            try db.resolveDroppedWrite(move, serverCopy: .live(anchor))
        }
        #expect(try db.event(id: sibling.id)?.startAt == sibling.startAt)
        #expect(try db.event(id: sibling.id)?.endAt == sibling.endAt)
    }

    @Test func pinnedDurationAndProgressRefreshTheLocalBlock() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "pin")
        task.pinnedStart = Fixtures.t0
        try db.saveTask(task)
        task.durationMinutes = 120
        try db.saveTask(task)
        #expect(try db.placements(in: Fixtures.allTime).first?.endAt == Fixtures.t0.addingTimeInterval(7200))
        task.completedMinutes = 30
        try db.saveTask(task)
        #expect(try db.placements(in: Fixtures.allTime).first?.endAt == Fixtures.t0.addingTimeInterval(5400))
    }

    @Test func schedulerReplyPreservesAnotherQueuedPinAndDropCleansItUp() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "pin")
        task.pinnedStart = Fixtures.t0
        try db.saveTask(task)
        try db.apply(SchedulingResult(), computedAt: Fixtures.t0)
        #expect(try db.placements(in: Fixtures.allTime).map(\.taskId) == [task.id])
        task.pinnedStart = Fixtures.t0.addingTimeInterval(3600)
        try db.saveTask(task)
        let write = try #require(try db.pendingWrites().first)
        var server = task
        server.pinnedStart = nil
        try db.resolveDroppedWrite(write, serverCopy: .live(server))
        #expect(try db.placements(in: Fixtures.allTime).isEmpty)
    }

    @Test func rejectedPinnedCreationRetainsItsTextButNotAStrandedPlacement() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "rejected-pin")
        task.pinnedStart = Fixtures.t0
        try db.saveTask(task)
        let write = try #require(try db.pendingWrites().first)
        try db.resolveDroppedWrite(write, serverCopy: .missing)
        #expect(try db.task(id: task.id)?.title == task.title)
        #expect(try db.placements(in: Fixtures.allTime).isEmpty)
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func deadlineEditClearsObsoleteUnscheduledReason() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "late", dueAt: Fixtures.t0)
        task.deadlineType = .hard
        let result = SchedulingResult(unscheduled: [.init(taskId: task.id, reason: "no_fit_before_hard_deadline", unplacedMinutes: 60)])
        try db.apply(SyncResponse(cursor: "c", tasks: [task]))
        try db.apply(result, computedAt: Fixtures.t0)
        task.deadlineType = .none
        task.dueAt = nil
        try db.saveTask(task)
        #expect(try db.unscheduled().isEmpty)
    }

    @Test func changingStartClearsStalePlacementsWithoutANetworkRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let now = Fixtures.instant("2026-11-13T20:00:00Z")
        let task = Fixtures.task(id: "t", dueAt: now)
        try db.apply(SyncResponse(cursor: "c", tasks: [task], placements: [Fixtures.placement(
            id: "p", taskId: task.id, start: "2026-11-13T21:00:00Z", end: "2026-11-13T22:00:00Z")]))
        var pushed = task
        pushed.startAt = Fixtures.instant("2026-11-14T00:00:00Z")
        pushed.dueAt = Fixtures.instant("2026-11-15T20:00:00Z")
        try db.saveTask(pushed)
        #expect(try db.placements(in: Fixtures.allTime).isEmpty)
        let queue = try #require(try db.pendingWrites().first)
        #expect(try body(queue)["startAt"] as? String == JSONCoding.formatInstant(pushed.startAt!))
        #expect(try body(queue)["dueAt"] as? String == JSONCoding.formatInstant(pushed.dueAt!))
    }

    @Test func pausingProjectRemovesItsTaskPlacementsLocally() throws {
        let db = try AppDatabase.inMemory()
        var project = Project(id: "p", name: "Project", createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        var task = Fixtures.task(id: "t")
        task.projectId = project.id
        try db.apply(SyncResponse(cursor: "c", tasks: [task], placements: [Fixtures.placement(
            id: "p1", taskId: task.id, start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")], projects: [project]))
        project.status = .onHold
        try db.saveProject(project)
        #expect(try db.placements(in: Fixtures.allTime).isEmpty)
    }

    @Test func completedParallelTaskDoesNotStayAlongsideItsCompanion() throws {
        var done = Fixtures.task(id: "done", completedAt: Fixtures.t0)
        done.completedMinutes = done.durationMinutes
        let live = Fixtures.task(id: "live")
        var first = Fixtures.placement(id: "p1", taskId: done.id, start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        first.lane = 1
        var second = first
        second.id = "p2"
        second.taskId = live.id
        second.lane = 2
        #expect(ParallelWork.companionTitles(placements: [first, second], tasksById: [done.id: done, live.id: live], planBlocks: []).isEmpty)
    }

    @Test func calendarQueuePushesMergedFlagsAndProtectsNewerToggles() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", calendars: [Fixtures.calendar()]))
        try db.setCalendarSelected(id: "cal", selected: false)
        let first = try #require(try db.pendingWrites().first)
        try db.setCalendarBlocksScheduling(id: "cal", blocksScheduling: false)
        try db.completePendingWrite(first, record: nil as CalendarInfo?, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
        #expect(try db.pendingWrites().count == 1)
        let transport = FakeTransport([.ok(try Fixtures.deleteResponse())])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 1)
        let request = try #require(transport.requests.first)
        #expect(request.method == "PATCH" && request.path == "/api/calendars/cal")
        let fields = try JSONCoding.decoder.decode([String: Bool].self, from: #require(request.body))
        #expect(fields == ["selected": false, "blocksScheduling": false])
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.calendars().first?.selected == false)
        #expect(try db.calendars().first?.blocksScheduling == false)
    }

    @Test func calendarActivationIsPushedBeforeAnEventEvenAfterAnotherToggle() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", calendars: [Fixtures.calendar(selected: false)]))
        try db.setCalendarSelected(id: "cal", selected: true)
        let event = Fixtures.event(id: "new", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        try db.saveEvent(event)
        try db.setCalendarBlocksScheduling(id: "cal", blocksScheduling: false)
        let transport = FakeTransport([
            .ok(try Fixtures.deleteResponse()),
            .ok(try Fixtures.putResponse("event", event)),
        ])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 2)
        #expect(transport.requests.map(\.path) == ["/api/calendars/cal", "/api/events/new"])
    }

    @Test func removingSeriesMoveRestoresSiblingsAfterReopeningTheStore() throws {
        let db = try AppDatabase.inMemory()
        let anchor = series("e1", day: "09")
        let sibling = series("e2", day: "10")
        try db.apply(SyncResponse(cursor: "c", events: [anchor, sibling]))
        try db.moveEventSeries(instanceId: anchor.id, start: anchor.startAt!.addingTimeInterval(3600), end: anchor.endAt!.addingTimeInterval(3600))
        let reopened = try AppDatabase(writer: db.writer)
        var renamed = try #require(try reopened.event(id: sibling.id))
        renamed.summary = "New summary from sync"
        try reopened.writer.write { try renamed.update($0) }
        let write = try #require(try reopened.pendingWrites().first)
        try reopened.removePendingWrite(seq: #require(write.seq))
        #expect(try reopened.event(id: sibling.id)?.startAt == sibling.startAt)
        #expect(try reopened.event(id: sibling.id)?.summary == renamed.summary)
    }

    @Test func deletingAnUnsentCreationTreatsServer404AsSuccess() async throws {
        let db = try AppDatabase.inMemory()
        let task = Fixtures.task(id: "new")
        try db.saveTask(task)
        try db.deleteTask(id: task.id)
        let transport = FakeTransport([.error(404, "task not found")])
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "test")
        let client = SyncClient(database: db, config: config, transport: transport)
        #expect(try await client.push() == 1)
        #expect(await client.lastRejectedWrites.isEmpty)
        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.task(id: task.id) == nil)
    }
}
