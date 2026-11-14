import Foundation
import Testing
@testable import FloridaCore

@Suite struct TaskDraftFieldsTests {
    @Test func serverSchedulingFieldsSurviveDraftDecodingAndEncoding() throws {
        let data = Data("""
            {"title":"Parsed task","durationMinutes":90,"priority":"high","deadlineType":"soft",\
            "context":"errand","projectId":"project-audit","attention":"shared","rationale":"A proposal"}
            """.utf8)
        let draft = try JSONCoding.decoder.decode(TaskDraft.self, from: data)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(draft)) as? [String: Any])
        #expect(encoded["context"] as? String == "errand")
        #expect(encoded["projectId"] as? String == "project-audit")
        #expect(encoded["attention"] as? String == "shared")
    }

    @Test func legacyDraftsDoNotRequireSchedulingFields() throws {
        let data = Data("""
            {"title":"Legacy task","durationMinutes":30,"priority":"medium","deadlineType":"none","rationale":""}
            """.utf8)
        let draft = try JSONCoding.decoder.decode(TaskDraft.self, from: data)
        #expect(draft.title == "Legacy task")
        #expect(draft.context == nil)
        #expect(draft.projectId == nil)
        #expect(draft.attention == nil)
    }

    private let now = Date(timeIntervalSince1970: 1_794_566_400)

    private func task() -> TaskItem {
        TaskItem(id: "review", categoryId: "inbox", title: "Review", durationMinutes: 30,
                 createdAt: now, updatedAt: now)
    }

    @Test func acceptedSchedulingContextReachesTheTask() throws {
        let data = Data("""
            {"title":"Parsed task","durationMinutes":90,"priority":"high","deadlineType":"soft",\
            "context":"errand","projectId":"project-audit","attention":"shared","rationale":"A proposal"}
            """.utf8)
        let draft = try JSONCoding.decoder.decode(TaskDraft.self, from: data)
        let project = Project(id: "project-audit", name: "Audit", createdAt: now, updatedAt: now)
        let applied = draft.applyingSchedulingContext(to: task(), projects: [project])
        #expect(applied.context == .errand)
        #expect(applied.projectId == project.id)
        #expect(applied.attention == .shared)
    }

    @Test func absentSchedulingContextPreservesExistingFields() throws {
        let data = Data("""
            {"title":"Legacy task","durationMinutes":30,"priority":"medium","deadlineType":"none","rationale":""}
            """.utf8)
        let legacy = try JSONCoding.decoder.decode(TaskDraft.self, from: data)
        let nullData = Data("""
            {"title":"Parsed task","durationMinutes":30,"priority":"medium","deadlineType":"none",\
            "context":null,"projectId":null,"attention":null,"rationale":""}
            """.utf8)
        let nullFields = try JSONCoding.decoder.decode(TaskDraft.self, from: nullData)
        var original = task()
        original.context = .home
        original.projectId = "existing"
        original.attention = .full
        #expect(legacy.applyingSchedulingContext(to: original, projects: []) == original)
        #expect(nullFields.applyingSchedulingContext(to: original, projects: []) == original)
        #expect(legacy.applyingSchedulingContext(to: task(), projects: []) == task())
    }

    @Test func unknownAndDeletedProjectsAreNotApplied() {
        var original = task()
        original.projectId = "existing"
        let draft = TaskDraft(title: "Parsed task", durationMinutes: 30,
                              context: .office, projectId: "stale", attention: .full)
        let deleted = Project(id: "stale", name: "Deleted", createdAt: now, updatedAt: now, deletedAt: now)
        for projects in [[], [deleted]] {
            let applied = draft.applyingSchedulingContext(to: original, projects: projects)
            #expect(applied.projectId == original.projectId)
            #expect(applied.context == .office)
            #expect(applied.attention == .full)
        }
    }

    @Test func explicitLocalFieldsStillWinAfterAcceptingAIContext() {
        let local = QuickAddParser.parse("Review #work @home =45m !2 https://example.com/review",
                                         now: now, calendar: PacificTestCalendar.calendar)
        let proposal = TaskDraft(title: "AI review", durationMinutes: 90,
                                 context: .errand, projectId: "audit", attention: .shared)
        let project = Project(id: "audit", name: "Audit", createdAt: now, updatedAt: now)
        var aiTask = task()
        aiTask.durationMinutes = proposal.durationMinutes
        aiTask.priority = proposal.priority
        let accepted = proposal.applyingSchedulingContext(to: aiTask, projects: [project])
        let applied = local.applyingExplicitFields(to: accepted, categoryId: "explicit-work")
        #expect(applied.context == .home)
        #expect(applied.projectId == project.id)
        #expect(applied.attention == .shared)
        #expect(applied.categoryId == "explicit-work")
        #expect(applied.durationMinutes == 45)
        #expect(applied.priority == .high)
        #expect(applied.source == local.source)
        #expect(applied.source?.url == "https://example.com/review")
    }
}
