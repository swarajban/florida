import Foundation
import Testing
@testable import FloridaKit

/// Projects, day overrides and the scheduler output that came with them: stored, queued and pushed.
@Suite struct ProjectStoreTests {
    let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "secret-token")

    func project(_ id: String, status: ProjectStatus = .active, parallel: Bool = false, deletedAt: Date? = nil) -> Project {
        Project(
            id: id, name: id.capitalized, status: status, parallel: parallel,
            createdAt: Fixtures.t0, updatedAt: Fixtures.t0, deletedAt: deletedAt)
    }

    func day(_ date: String, _ kind: DayKind, deletedAt: Date? = nil) -> DayOverride {
        DayOverride(date: date, kind: kind, createdAt: Fixtures.t0, updatedAt: Fixtures.t0, deletedAt: deletedAt)
    }

    func held(_ id: String, start: String, end: String) -> ProjectPlacement {
        ProjectPlacement(
            id: id, projectId: "florida", weekOf: "2026-11-08", startAt: Fixtures.instant(start), endAt: Fixtures.instant(end),
            computedAt: Fixtures.t0)
    }

    // MARK: The agenda

    @Test func aDaysAgendaCarriesItsGymAndActiveProjectTimeOnly() throws {
        let db = try AppDatabase.inMemory()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let gymBlock = RoutineBlock(
            id: "gym", name: "Gym", days: [2], start: "09:00", end: "10:15", allows: [], optional: false,
            createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        var paused = held("pp2", start: "2026-11-10T20:00:00Z", end: "2026-11-10T21:00:00Z")
        paused.projectId = "taxes"
        try db.apply(SyncResponse(
            cursor: "c1",
            routineBlocks: [gymBlock],
            projects: [project("florida"), project("taxes", status: .onHold)],
            projectPlacements: [
                held("pp1", start: "2026-11-10T18:00:00Z", end: "2026-11-10T19:00:00Z"),
                paused,
                // The next day's time is not on this day's agenda.
                held("pp3", start: "2026-11-11T18:00:00Z", end: "2026-11-11T19:00:00Z"),
            ],
            routineOccurrences: [RoutineOccurrence(
                id: "o1", blockId: "gym", startAt: Fixtures.instant("2026-11-10T17:00:00Z"),
                endAt: Fixtures.instant("2026-11-10T18:15:00Z"), computedAt: Fixtures.t0)]))

        let agenda = try db.agenda(for: Fixtures.instant("2026-11-10T12:00:00Z"), calendar: utc)
        #expect(agenda.planBlocks.map(\.id) == ["commitment:gym@1794330000", "project:florida@1794333600"])
        #expect(agenda.planBlocks.map(\.title) == ["Gym", "Florida"])
        #expect(try db.agenda(for: Fixtures.instant("2026-11-12T12:00:00Z"), calendar: utc).planBlocks.isEmpty)
    }

    // MARK: Pulling

    @Test func aPullStoresProjectsAndDaysAndDropsTombstonedOnes() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(
            cursor: "c1",
            projects: [project("florida", parallel: true), project("taxes", status: .onHold)],
            dayOverrides: [day("2026-11-12", .office), day("2026-11-13", .off)]))
        #expect(try db.projects().map(\.id) == ["florida", "taxes"])
        #expect(try db.project(id: "taxes")?.status == .onHold)
        #expect(try db.dayOverrides().map(\.kind) == [.office, .off])

        try db.apply(SyncResponse(
            cursor: "c2",
            projects: [project("taxes", deletedAt: Fixtures.t0)],
            dayOverrides: [day("2026-11-12", .office, deletedAt: Fixtures.t0)]))
        #expect(try db.projects().map(\.id) == ["florida"])
        #expect(try db.dayOverrides().map(\.date) == ["2026-11-13"])
    }

    @Test func aPullLeavesAProjectOrDayWithAQueuedWriteAlone() throws {
        let db = try AppDatabase.inMemory()
        var local = project("florida")
        local.name = "Florida v2"
        try db.saveProject(local, now: Fixtures.t0)
        try db.setDay("2026-11-12", kind: .home, now: Fixtures.t0)

        try db.apply(SyncResponse(cursor: "c", projects: [project("florida")], dayOverrides: [day("2026-11-12", .off)]))
        #expect(try db.project(id: "florida")?.name == "Florida v2")
        #expect(try db.dayOverrides().map(\.kind) == [.home])
    }

    @Test func aPullReplacesProjectTimeCommitmentsThePlanSummaryAndBriefs() throws {
        let db = try AppDatabase.inMemory()
        let gym = RoutineOccurrence(
            id: "o1", blockId: "gym", startAt: Fixtures.instant("2026-11-10T17:00:00Z"),
            endAt: Fixtures.instant("2026-11-10T18:15:00Z"), computedAt: Fixtures.t0)
        let brief = Brief(
            id: "b1", kind: .daily, date: "2026-11-09", headline: "Light day", body: "Two blocks.",
            createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        try db.apply(SyncResponse(
            cursor: "c1",
            projectPlacements: [held("pp1", start: "2026-11-09T18:00:00Z", end: "2026-11-09T19:00:00Z")],
            routineOccurrences: [gym],
            missed: [MissedCommitment(blockId: "gym", weekOf: "2026-11-15")],
            capacity: [DayCapacity(date: "2026-11-09", freeMinutes: .init(computer: 90, errand: 30))],
            briefs: [brief]))
        #expect(try db.projectPlacements().map(\.id) == ["pp1"])
        #expect(try db.routineOccurrences() == [gym])
        #expect(try db.planSummary().missed == [MissedCommitment(blockId: "gym", weekOf: "2026-11-15")])
        #expect(try db.planSummary().capacity.first?.freeMinutes[.computer] == 90)
        #expect(try db.briefs() == [brief])

        // The next pull is the whole truth: what it does not list is gone.
        try db.apply(SyncResponse(cursor: "c2"))
        #expect(try db.projectPlacements().isEmpty && db.routineOccurrences().isEmpty && db.briefs().isEmpty)
        #expect(try db.planSummary() == PlanSummary())
    }

    // MARK: Scheduler runs

    @Test func aSchedulerRunReplacesUpcomingProjectTimeAndKeepsWhatAlreadyHappened() throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", projectPlacements: [
            held("spent", start: "2026-11-09T17:00:00Z", end: "2026-11-09T18:00:00Z"),
            held("stale", start: "2026-11-10T17:00:00Z", end: "2026-11-10T18:00:00Z"),
        ]))
        // A run's result lists only what is still ahead; the server keeps ended blocks as time spent.
        let result = SchedulingResult(
            routine: [.init(blockId: "gym", start: Fixtures.instant("2026-11-11T17:00:00Z"), end: Fixtures.instant("2026-11-11T18:15:00Z"))],
            missed: [MissedCommitment(blockId: "gym", weekOf: "2026-11-15")],
            projectPlacements: [.init(
                projectId: "florida", weekOf: "2026-11-08", start: Fixtures.instant("2026-11-12T17:00:00Z"),
                end: Fixtures.instant("2026-11-12T18:00:00Z"), lane: 1)])
        try db.apply(result, computedAt: Fixtures.instant("2026-11-09T20:00:00Z"))

        let rows = try db.projectPlacements()
        #expect(rows.map(\.startAt) == [Fixtures.instant("2026-11-09T17:00:00Z"), Fixtures.instant("2026-11-12T17:00:00Z")])
        #expect(rows.first?.id == "spent")
        #expect(rows.last?.lane == 1)
        #expect(try db.routineOccurrences().map(\.blockId) == ["gym"])
        #expect(try db.planSummary().missed.map(\.weekOf) == ["2026-11-15"])
    }

    // MARK: Local writes

    @Test func savingAProjectTwiceQueuesOnePutWithTheLatestBody() throws {
        let db = try AppDatabase.inMemory()
        var florida = project("florida")
        try db.saveProject(florida, now: Fixtures.t0)
        florida.status = .thinking
        florida.nextStep = "Ship lanes"
        try db.saveProject(florida, now: Fixtures.instant("2026-11-08T10:00:00Z"))

        let pending = try db.pendingWrites()
        #expect(pending.map(\.entity) == [.project] && pending.map(\.op) == [.put])
        let body = try JSONCoding.decoder.decode(ProjectWrite.self, from: try #require(pending.first?.body))
        #expect(body.status == .thinking && body.nextStep == "Ship lanes")
        #expect(try db.project(id: "florida")?.updatedAt == Fixtures.instant("2026-11-08T10:00:00Z"))
    }

    @Test func deletingAProjectUnfilesItsTasksWithoutQueuingTaskWrites() throws {
        let db = try AppDatabase.inMemory()
        var inProject = Fixtures.task(id: "t1")
        inProject.projectId = "florida"
        var elsewhere = Fixtures.task(id: "t2")
        elsewhere.projectId = "taxes"
        try db.apply(SyncResponse(cursor: "c", tasks: [inProject, elsewhere], projects: [project("florida"), project("taxes")]))

        try db.deleteProject(id: "florida", now: Fixtures.t0)
        #expect(try db.projects().map(\.id) == ["taxes"])
        #expect(try db.task(id: "t1")?.projectId == nil)
        #expect(try db.task(id: "t2")?.projectId == "taxes")
        // The server unfiles the tasks itself when it deletes the project.
        let pending = try db.pendingWrites()
        #expect(pending.map(\.entity) == [.project] && pending.map(\.op) == [.delete])
    }

    @Test func deletingAProjectUnfilesTheQueuedWritesOfItsTasks() throws {
        let db = try AppDatabase.inMemory()
        var moved = Fixtures.task(id: "moved")
        var elsewhere = Fixtures.task(id: "elsewhere")
        try db.apply(SyncResponse(cursor: "c", tasks: [moved, elsewhere], projects: [project("taxes")]))
        // The project and a new task in it are both still queued, with two edits of older tasks.
        try db.saveProject(project("florida"), now: Fixtures.t0)
        var new = Fixtures.task(id: "new", title: "Write the pitch")
        new.projectId = "florida"
        try db.saveTask(new, now: Fixtures.t0)
        moved.projectId = "florida"
        moved.title = "Renamed too"
        try db.saveTask(moved, now: Fixtures.t0)
        elsewhere.projectId = "taxes"
        try db.saveTask(elsewhere, now: Fixtures.t0)

        try db.deleteProject(id: "florida", now: Fixtures.instant("2026-11-08T00:05:00Z"))

        var sent: [String: [String: Any]] = [:]
        for write in try db.pendingWrites() where write.entity == .task {
            sent[write.entityId] = try #require(JSONSerialization.jsonObject(with: try #require(write.body)) as? [String: Any])
        }
        // The server answers "unknown projectId" to a project it never saw, dropping the whole write.
        #expect(sent["new"]?["projectId"] is NSNull)
        #expect(sent["new"]?["title"] as? String == "Write the pitch")
        #expect(sent["moved"]?["projectId"] is NSNull)
        #expect(sent["moved"]?["title"] as? String == "Renamed too", "the rest of the edit is kept")
        #expect(sent["elsewhere"]?["projectId"] as? String == "taxes")
    }

    @Test func settingThenClearingADayCollapsesToOneDelete() throws {
        let db = try AppDatabase.inMemory()
        try db.clearDay("2026-11-12", now: Fixtures.t0)
        #expect(try db.pendingWrites().isEmpty, "clearing a day on its routine does nothing")

        try db.setDay("2026-11-12", kind: .office, note: "offsite", now: Fixtures.t0)
        try db.setDay("2026-11-12", kind: .off, now: Fixtures.instant("2026-11-08T10:00:00Z"))
        var pending = try db.pendingWrites()
        #expect(pending.map(\.op) == [.put] && pending.map(\.entityId) == ["2026-11-12"])
        let body = try JSONCoding.decoder.decode(DayOverrideWrite.self, from: try #require(pending.first?.body))
        #expect(body.kind == .off && body.note == nil)
        #expect(try db.dayOverrides().first?.createdAt == Fixtures.t0, "an edit keeps the first write's creation time")

        try db.clearDay("2026-11-12", now: Fixtures.instant("2026-11-08T11:00:00Z"))
        pending = try db.pendingWrites()
        #expect(pending.map(\.entity) == [.dayOverride] && pending.map(\.op) == [.delete])
        #expect(try db.dayOverrides().isEmpty)
    }

    @Test func takingATaskOutOfItsProjectSendsAnExplicitNull() throws {
        let db = try AppDatabase.inMemory()
        var task = Fixtures.task(id: "t1")
        task.projectId = "florida"
        task.attention = .shared
        try db.apply(SyncResponse(cursor: "c", tasks: [task], projects: [project("florida")]))

        task.projectId = nil
        try db.saveTask(task, now: Fixtures.t0)
        let write = try #require(try db.pendingWrites().first)
        #expect(write.op == .patch)
        let sent = try #require(write.body)
        let object = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(object["projectId"] is NSNull, "leaving the key out would keep the project on the server")
        #expect(object["attention"] == nil, "an unchanged field is not sent")
    }

    @Test func storingABriefReplacesTheOneOfItsKind() throws {
        let db = try AppDatabase.inMemory()
        func brief(_ id: String, _ kind: BriefKind, _ date: String) -> Brief {
            Brief(id: id, kind: kind, date: date, headline: id, body: "", createdAt: Fixtures.t0, updatedAt: Fixtures.t0)
        }
        try db.storeBrief(brief("mon", .daily, "2026-11-09"))
        try db.storeBrief(brief("week", .weekly, "2026-11-08"))
        try db.storeBrief(brief("tue", .daily, "2026-11-10"))
        #expect(try db.briefs().map(\.id) == ["tue", "week"])
    }

    // MARK: Pushing

    @Test func pushSendsProjectAndDayWritesAndStoresTheServersCopies() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveProject(project("florida"), now: Fixtures.t0)
        try db.setDay("2026-11-12", kind: .office, now: Fixtures.instant("2026-11-08T00:01:00Z"))
        try db.apply(SyncResponse(cursor: "c", dayOverrides: [day("2026-11-13", .off)]))
        try db.clearDay("2026-11-13", now: Fixtures.instant("2026-11-08T00:02:00Z"))

        var stored = project("florida")
        stored.sortOrder = 7
        let scheduling = SchedulingResult(projectPlacements: [.init(
            projectId: "florida", weekOf: "2026-11-08", start: Fixtures.instant("2030-01-07T17:00:00Z"),
            end: Fixtures.instant("2030-01-07T18:00:00Z"))])
        let transport = FakeTransport([
            .ok(try Fixtures.putResponse("project", stored)),
            .ok(try Fixtures.putResponse("dayOverride", day("2026-11-12", .office))),
            .ok(try Fixtures.deleteResponse(scheduling: scheduling)),
        ])

        let pushed = try await SyncClient(database: db, config: config, transport: transport).push()
        #expect(pushed == 3)
        #expect(transport.requests.map(\.method) == ["PUT", "PUT", "DELETE"])
        #expect(transport.requests.map(\.path) == ["/api/projects/florida", "/api/day-overrides/2026-11-12", "/api/day-overrides/2026-11-13"])
        let sent = try JSONCoding.decoder.decode(DayOverrideWrite.self, from: try #require(transport.requests[1].body))
        #expect(sent.kind == .office)

        #expect(try db.pendingWrites().isEmpty)
        #expect(try db.project(id: "florida")?.sortOrder == 7, "the server's copy replaces the local one")
        #expect(try db.dayOverrides().map(\.date) == ["2026-11-12"])
        #expect(try db.projectPlacements().map(\.projectId) == ["florida"], "the last answer's plan is applied")
    }

    @Test func aServerWithoutTheRouteKeepsTheWriteQueuedAndPushesTheRest() async throws {
        // Hono answers a route it does not have with plain text, not its `{error}` JSON.
        let db = try AppDatabase.inMemory()
        try db.saveProject(project("florida"), now: Fixtures.t0)
        try db.saveTask(Fixtures.task(id: "t1"), now: Fixtures.instant("2026-11-08T00:01:00Z"))
        let transport = FakeTransport([
            .json(status: 404, body: Data("404 Not Found".utf8)),
            .ok(try Fixtures.putResponse("task", Fixtures.task(id: "t1"))),
        ])
        let client = SyncClient(database: db, config: config, transport: transport)

        let pushed = try await client.push()
        #expect(pushed == 1)
        #expect(transport.requests.map(\.path) == ["/api/projects/florida", "/api/tasks/t1"])
        #expect(try db.pendingWrites().map(\.entity) == [.project], "kept for a server that has the route")
        #expect(try db.project(id: "florida") != nil)
        #expect(await client.lastRejectedWrites.isEmpty)
    }

    @Test func aProjectSavedAgainIsStillPushedBeforeTheTaskFiledUnderIt() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveProject(project("florida"), now: Fixtures.t0)
        var task = Fixtures.task(id: "t1")
        task.projectId = "florida"
        try db.saveTask(task, now: Fixtures.instant("2026-11-08T00:01:00Z"))
        // Saving again moves the project's write behind the task's in the queue.
        var renamed = project("florida")
        renamed.name = "Florida 2"
        try db.saveProject(renamed, now: Fixtures.instant("2026-11-08T00:02:00Z"))
        #expect(try db.pendingWrites().map(\.entity) == [.task, .project])
        let transport = FakeTransport([
            .ok(try Fixtures.putResponse("project", renamed)),
            .ok(try Fixtures.putResponse("task", task)),
        ])
        let client = SyncClient(database: db, config: config, transport: transport)

        #expect(try await client.push() == 2)
        // In queue order the server answers the task with 400 "unknown projectId florida".
        #expect(transport.requests.map(\.path) == ["/api/projects/florida", "/api/tasks/t1"])
        #expect(try db.task(id: "t1")?.projectId == "florida")
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func aTaskWaitsUnsentWhileTheServerHasNoRouteForItsProject() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveProject(project("florida"), now: Fixtures.t0)
        var filed = Fixtures.task(id: "filed")
        filed.projectId = "florida"
        filed.attention = .shared
        try db.saveTask(filed, now: Fixtures.instant("2026-11-08T00:01:00Z"))
        try db.saveTask(Fixtures.task(id: "loose"), now: Fixtures.instant("2026-11-08T00:02:00Z"))
        // A server from before projects accepts a task and drops the project from it, and its
        // answer would then replace the local row.
        let old = FakeTransport([
            .json(status: 404, body: Data("404 Not Found".utf8)),
            .ok(try Fixtures.putResponse("task", Fixtures.task(id: "loose"))),
        ])
        let client = SyncClient(database: db, config: config, transport: old)

        #expect(try await client.push() == 1)
        #expect(old.requests.map(\.path) == ["/api/projects/florida", "/api/tasks/loose"])
        #expect(try db.pendingWrites().map(\.entityId) == ["florida", "filed"])
        #expect(try db.task(id: "filed")?.projectId == "florida")
        #expect(try db.task(id: "filed")?.attention == .shared)
        #expect(await client.lastRejectedWrites.isEmpty)

        // Once the server has projects, both go.
        let new = FakeTransport([
            .ok(try Fixtures.putResponse("project", project("florida"))),
            .ok(try Fixtures.putResponse("task", filed)),
        ])
        #expect(try await SyncClient(database: db, config: config, transport: new).push() == 2)
        #expect(new.requests.map(\.path) == ["/api/projects/florida", "/api/tasks/filed"])
        #expect(try db.task(id: "filed")?.projectId == "florida")
        #expect(try db.pendingWrites().isEmpty)
    }

    @Test func aProjectTheServerRefusesIsResetToTheServersCopy() async throws {
        let db = try AppDatabase.inMemory()
        try db.apply(SyncResponse(cursor: "c", projects: [project("florida")]))
        var edited = project("florida")
        edited.name = ""
        try db.saveProject(edited, now: Fixtures.t0)
        let transport = FakeTransport([.error(400, "name is required"), try .ok(project("florida"))])
        let client = SyncClient(database: db, config: config, transport: transport)

        #expect(try await client.push() == 0)
        #expect(transport.requests.map(\.path) == ["/api/projects/florida", "/api/projects/florida"])
        #expect(transport.requests.map(\.method) == ["PUT", "GET"])
        #expect(try db.project(id: "florida")?.name == "Florida")
        #expect(try db.pendingWrites().isEmpty)
        #expect(await client.lastRejectedWrites.map(\.message) == ["name is required"])
    }
}
