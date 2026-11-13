import Foundation
import Testing
@testable import FloridaKit

@Suite struct LocalWriteReviewTests {
    @Test func manualPinOverridesFutureStartOnSaveAndSchedulerRefresh() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "manual-pin")
        task.startAt = Fixtures.instant("2026-11-10T00:00:00Z")
        task.pinnedStart = Fixtures.instant("2026-11-09T10:00:00Z")
        try db.saveTask(task)
        let saved = try db.placements(in: Fixtures.allTime)
        #expect(saved.count == 1)
        #expect(saved.first?.pinned == true)
        #expect(saved.first?.startAt == task.pinnedStart)
        #expect(saved.first?.endAt == task.pinnedStart?.addingTimeInterval(3600))
        try db.apply(SchedulingResult(), computedAt: Fixtures.t0)
        let refreshed = try db.placements(in: Fixtures.allTime)
        #expect(refreshed.count == 1)
        #expect(refreshed.first?.pinned == true)
        #expect(refreshed.first?.startAt == task.pinnedStart)
        #expect(refreshed.first?.endAt == task.pinnedStart?.addingTimeInterval(3600))
    }

    @Test func pendingCategoryDeleteKeepsTaskAndProjectReassignmentAcrossPulls() throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        var task = Fixtures.task(id: "task", categoryId: category.id)
        var project = Project(id: "project", name: "Project", categoryId: category.id, createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        try db.apply(SyncResponse(cursor: "c", categories: [category], tasks: [task], projects: [project]))
        try db.deleteCategory(id: category.id)
        task.notes = "A newer remote note"
        project.notes = "A newer project note"
        try db.apply(SyncResponse(cursor: "overlapping", tasks: [task], projects: [project]))
        #expect(try db.task(id: task.id)?.categoryId == TaskCategory.inboxId)
        #expect(try db.project(id: project.id)?.categoryId == nil)
        #expect(try db.task(id: task.id)?.notes == task.notes)
        #expect(try db.project(id: project.id)?.notes == project.notes)
        #expect(try db.pendingWrites().map(\.entity) == [.category])
        #expect(try db.pendingWrites().map(\.op) == [.delete])
    }

    @Test(arguments: [false, true])
    func pendingCategoryDeleteKeepsReassignmentAcrossOlderTaskAndProjectAcceptance(_ creating: Bool) throws {
        let db = try AppDatabase.inMemory()
        let category = Fixtures.category(id: "work")
        var task = Fixtures.task(id: "task", categoryId: category.id)
        var project = Project(id: "project", name: "Project", categoryId: category.id, createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        try db.apply(SyncResponse(cursor: "c", categories: [category], tasks: creating ? [] : [task], projects: [project]))
        task.title = "Title sent before category deletion"
        project.name = "Name sent before category deletion"
        try db.saveTask(task)
        try db.saveProject(project)
        let writes = try db.pendingWrites()
        let taskWrite = try #require(writes.first { $0.entity == .task })
        let projectWrite = try #require(writes.first { $0.entity == .project })
        #expect(taskWrite.op == (creating ? .put : .patch))
        try db.deleteCategory(id: category.id)
        task.notes = "Server task metadata"
        project.notes = "Server project metadata"
        try db.completePendingWrite(taskWrite, record: task, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
        #expect(try db.task(id: task.id)?.categoryId == TaskCategory.inboxId)
        #expect(try db.task(id: task.id)?.title == task.title)
        #expect(try db.task(id: task.id)?.notes == task.notes)
        try db.completePendingWrite(projectWrite, record: project, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
        #expect(try db.task(id: task.id)?.categoryId == TaskCategory.inboxId)
        #expect(try db.project(id: project.id)?.categoryId == nil)
        #expect(try db.project(id: project.id)?.name == project.name)
        #expect(try db.project(id: project.id)?.notes == project.notes)
        #expect(try db.pendingWrites().map(\.entity) == [.category])
    }

    @Test(arguments: [false, true])
    func acknowledgedSeriesMoveBecomesTheLaterMovesRollbackBaseline(_ rejected: Bool) throws {
        let db = try AppDatabase.inMemory()
        var anchor = Fixtures.event(id: "anchor", start: "2026-11-09T10:00:00Z", end: "2026-11-09T11:00:00Z")
        anchor.recurringEventId = "series"
        var sibling = Fixtures.event(id: "sibling", start: "2026-11-10T10:00:00Z", end: "2026-11-10T11:00:00Z")
        sibling.recurringEventId = "series"
        try db.apply(SyncResponse(cursor: "c", events: [anchor, sibling]))
        let firstStart = Fixtures.instant("2026-11-09T11:00:00Z")
        let firstEnd = Fixtures.instant("2026-11-09T11:45:00Z")
        try db.moveEventSeries(instanceId: anchor.id, start: firstStart, end: firstEnd)
        let first = try #require(try db.pendingWrites().first)
        let secondStart = Fixtures.instant("2026-11-09T12:00:00Z")
        let secondEnd = Fixtures.instant("2026-11-09T13:30:00Z")
        try db.moveEventSeries(instanceId: anchor.id, start: secondStart, end: secondEnd)
        let second = try #require(try db.pendingWrites().first)
        var accepted = anchor
        accepted.startAt = firstStart
        accepted.endAt = firstEnd
        try db.completePendingWrite(first, record: accepted, scheduling: SchedulingResult(), computedAt: Fixtures.t0)
        #expect(try db.event(id: anchor.id)?.startAt == secondStart)
        #expect(try db.event(id: sibling.id)?.startAt == Fixtures.instant("2026-11-10T12:00:00Z"))
        #expect(try db.event(id: sibling.id)?.endAt == Fixtures.instant("2026-11-10T13:30:00Z"))
        #expect(try db.pendingWrites().first?.seq == second.seq)
        #expect(try db.pendingWrites().first?.body == second.body)
        let queued = try JSONCoding.decoder.decode(EventWrite.self, from: #require(second.body))
        #expect(queued.startAt == secondStart && queued.endAt == secondEnd && queued.scope == .series)
        let reopened = try AppDatabase(writer: db.writer)
        if rejected {
            try reopened.resolveDroppedWrite(second, serverCopy: .live(accepted))
            #expect(try reopened.event(id: anchor.id)?.startAt == firstStart)
        } else {
            try reopened.removePendingWrite(seq: #require(second.seq))
        }
        #expect(try reopened.event(id: sibling.id)?.startAt == Fixtures.instant("2026-11-10T11:00:00Z"))
        #expect(try reopened.event(id: sibling.id)?.endAt == Fixtures.instant("2026-11-10T11:45:00Z"))
        #expect(try reopened.pendingWrites().isEmpty)
    }
}
