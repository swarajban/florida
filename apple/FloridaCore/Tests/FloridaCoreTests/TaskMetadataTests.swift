import Foundation
import Testing
@testable import FloridaCore

@Suite struct TaskMetadataTests {
    private let now = Date(timeIntervalSince1970: 1_794_528_000)

    private func task() -> TaskItem {
        TaskItem(id: "task", categoryId: "work", title: "Review", durationMinutes: 30,
                 createdAt: now, updatedAt: now)
    }

    @Test func legacyTaskAndWriteDecodeMissingAndNullMetadata() throws {
        for null in [false, true] {
            for write in [false, true] {
                let encoded = try write ? JSONCoding.encoder.encode(TaskWrite(task())) : JSONCoding.encoder.encode(task())
                var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                for key in ["tags", "waitingOn", "waitingUntil"] {
                    if null { object[key] = NSNull() } else { object.removeValue(forKey: key) }
                }
                let data = try JSONSerialization.data(withJSONObject: object)
                if write {
                    let decoded = try JSONCoding.decoder.decode(TaskWrite.self, from: data)
                    #expect(decoded.tags.isEmpty && decoded.waitingOn == nil && decoded.waitingUntil == nil)
                } else {
                    let decoded = try JSONCoding.decoder.decode(TaskItem.self, from: data)
                    #expect(decoded.tags.isEmpty && decoded.waitingOn == nil && decoded.waitingUntil == nil)
                }
            }
        }
    }

    @Test func metadataRoundTripsAndNilWriteClearsExplicitly() throws {
        var task = task()
        task.tags = ["review", "client"]
        task.waitingOn = "Client reply"
        task.waitingUntil = now
        #expect(try JSONCoding.decoder.decode(TaskItem.self, from: JSONCoding.encoder.encode(task)) == task)
        let write = TaskWrite(task)
        #expect(try JSONCoding.decoder.decode(TaskWrite.self, from: JSONCoding.encoder.encode(write)) == write)
        #expect(write.tags == task.tags && write.waitingOn == task.waitingOn && write.waitingUntil == now)
        task.waitingOn = nil
        task.waitingUntil = nil
        task.tags = []
        let object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(TaskWrite(task))) as? [String: Any])
        #expect(object["waitingOn"] is NSNull && object["waitingUntil"] is NSNull)
        #expect(object["tags"] as? [String] == [])
    }

    @Test func normalizationKeepsFirstOrderAndPreservesTimingDecisions() throws {
        var task = task()
        task.tags = ["  Work ", "", "CLIENT", "work", "\n client\t", "\u{FEFF} Later\u{00A0}"]
        task.waitingOn = " \nClient reply\t"
        task.waitingUntil = now
        task.pinnedStart = now
        task.startAt = now.addingTimeInterval(-3600)
        task.dueAt = now.addingTimeInterval(3600)
        task.someday = true
        try task.normalizeMetadata()
        #expect(task.tags == ["work", "client", "later"])
        #expect(task.waitingOn == "Client reply" && task.waitingUntil == now)
        #expect(task.pinnedStart == nil && task.someday)
        #expect(task.startAt == now.addingTimeInterval(-3600) && task.dueAt == now.addingTimeInterval(3600))
        let normalized = task
        try task.normalizeMetadata()
        #expect(task == normalized)
        task.waitingOn = " \n\u{FEFF}"
        try task.normalizeMetadata()
        #expect(task.waitingOn == nil && task.waitingUntil == nil)
    }

    @Test func boundsApplyAfterNormalizationAndUseWireStringLength() throws {
        var task = task()
        task.tags = (0..<30).map { "tag-\($0)" } + ["TAG-0", " "]
        try task.normalizeMetadata()
        #expect(task.tags.count == 30)
        task.tags.append("extra")
        #expect(throws: TaskMetadataError.tooManyTags) { try task.normalizeMetadata() }
        task.tags = [String(repeating: "😀", count: 32)]
        try task.normalizeMetadata()
        task.tags = [String(repeating: "😀", count: 33)]
        #expect(throws: TaskMetadataError.tagTooLong) { try task.normalizeMetadata() }
        task.tags = ["é", "e\u{301}"]
        try task.normalizeMetadata()
        #expect(task.tags.count == 2)
        task.tags = ["ΟΣ", "ος", "İ", "i\u{307}"]
        try task.normalizeMetadata()
        #expect(task.tags == ["ος", "i\u{307}"])
        task.waitingOn = " " + String(repeating: "😀", count: 250) + " "
        try task.normalizeMetadata()
        task.waitingOn = String(repeating: "😀", count: 251)
        let invalid = task
        #expect(throws: TaskMetadataError.waitingOnTooLong) { try task.normalizeMetadata() }
        #expect(task == invalid)
    }

    @Test func waitingIsATriageDecisionButNotAnInboxCategoryDecision() {
        var task = task()
        #expect(task.needsTriage)
        task.waitingOn = "Client"
        #expect(!task.needsTriage)
        task.categoryId = TaskCategory.inboxId
        #expect(task.needsTriage)
        task.categoryId = "work"
        task.waitingOn = " \n "
        #expect(task.needsTriage)
    }

    @Test func eligibleFollowUpBlocksRemainVisibleWithoutPins() {
        var task = task()
        task.waitingOn = "Client"
        #expect(!task.allowsPlacement(at: now.addingTimeInterval(86_400)))
        task.waitingUntil = now
        #expect(!task.allowsPlacement(at: now.addingTimeInterval(-1)))
        #expect(task.allowsPlacement(at: now) && task.allowsPlacement(at: now.addingTimeInterval(86_400)))
        #expect(!task.allowsPlacement(at: now, pinned: true))
        task.someday = true
        #expect(!task.allowsPlacement(at: now))
    }

    @Test func waitingFiltersStaleSuggestionsAndParallelCompanionsWithoutHidingFollowUps() {
        var task = OptionalPicksTests.task("waiting")
        task.waitingOn = "Client"
        let early = OptionalPicksTests.suggestion(task.id, from: (20, 0), to: (21, 0))
        let eligible = OptionalPicksTests.suggestion(task.id, from: (21, 0), to: (22, 0))
        #expect(OptionalPicksTests.picks([early, eligible], tasks: [task]).isEmpty)
        task.waitingUntil = eligible.startAt
        #expect(OptionalPicksTests.picks([early, eligible], tasks: [task]).first?.picks.map(\.placement) == [eligible])
        let rows = [early, eligible].map {
            Placement(id: $0.id, taskId: task.id, startAt: $0.startAt, endAt: $0.endAt,
                      pinned: false, lane: 1, computedAt: now)
        }
        let block = PlanBlock(id: "project", kind: .project(projectId: "p"), title: "Project",
                              startAt: early.startAt, endAt: eligible.endAt, lane: 0)
        let titles = ParallelWork.companionTitles(placements: rows, tasksById: [task.id: task], planBlocks: [block])
        #expect(titles[early.id] == nil && titles[eligible.id] == ["Project"])
    }

    @Test func waitingNeverBlocksAvailabilityWithAStalePin() {
        var task = AvailabilityTests.task("waiting", pin: AvailabilityTests.hours(18, 19).start)
        task.waitingOn = "Client"
        task.waitingUntil = AvailabilityTests.hours(18, 19).start
        #expect(AvailabilityTests.free(tasks: [task], placements: [AvailabilityTests.placement(task.id, start: 20, end: 21)]) == AvailabilityTests.free())
    }

    @Test func recurrenceTemplateAndUndoRetainMetadata() throws {
        var before = task()
        before.tags = ["client"]
        before.waitingOn = "Client"
        before.waitingUntil = JSONCoding.parseInstant("2026-11-12T09:30:00-08:00")
        before.startAt = before.waitingUntil
        before.recurrence = TaskRecurrence(frequency: .week, timeZone: "America/Los_Angeles", startDate: "2026-11-09")
        var after = before
        after.prepareToEnableRecurrence()
        #expect(after.waitingUntil == JSONCoding.parseInstant("2026-11-09T09:30:00-08:00"))
        #expect(after.waitingUntil == after.startAt)
        #expect(after.tags == before.tags && after.waitingOn == before.waitingOn)
        after.tags = ["new"]
        after.waitingOn = "Someone else"
        let undo = try #require(TaskUndo(from: before, to: after))
        #expect(undo.stillApplies(to: after))
        #expect(undo.reverted(after) == before)
        var changed = after
        changed.waitingOn = "Newer change"
        #expect(!undo.stillApplies(to: changed))
    }
}
