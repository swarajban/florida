import Foundation
import Testing
@testable import FloridaCore

@Suite struct QuickAddExplicitFieldsTests {
    private let now = PacificTestCalendar.date(2026, 11, 12, 10)
    private let calendar = PacificTestCalendar.calendar

    private func aiTask() -> TaskItem {
        TaskItem(id: "review", categoryId: "guessed", title: "AI title", notes: "AI notes",
                 durationMinutes: 120, priority: .low, deadlineType: .hard,
                 dueAt: now, context: .computer, createdAt: now, updatedAt: now)
    }

    @Test func explicitFieldsSurviveAIReview() throws {
        let local = QuickAddParser.parse(
            "Review #work !2 =45m @office ^fri ~today *weekly // Keep this note",
            now: now, calendar: calendar)
        let task = local.applyingExplicitFields(to: aiTask(), categoryId: "selected-exact-id")
        #expect(task.title == "AI title")
        #expect(task.categoryId == "selected-exact-id")
        #expect(task.durationMinutes == 45)
        #expect(task.priority == .high)
        #expect(task.context == .office)
        #expect(task.notes == "Keep this note")
        #expect(task.deadlineType == .soft)
        #expect(task.dueAt == local.dueAt)
        #expect(task.recurrence == local.recurrence)
        #expect(try #require(task.recurrence).effectiveWeekdays == [5])
    }

    @Test func explicitNoDateOverridesAIGuess() {
        let local = QuickAddParser.parse("Review ^none", now: now, calendar: calendar)
        let task = local.applyingExplicitFields(to: aiTask())
        #expect(task.dueAt == nil)
        #expect(task.deadlineType == .none)
        #expect(task.categoryId == "guessed")
        #expect(task.durationMinutes == 120)
    }

    @Test func noExplicitFieldsKeepAIValues() {
        #expect(QuickAddDraft(title: "Free text").applyingExplicitFields(to: aiTask()) == aiTask())
    }

    @Test func explicitSourceSurvivesWithSmartAddFields() {
        let local = QuickAddParser.parse("Review https://github.com/o/r/pull/12 !2 ^none", now: now, calendar: calendar)
        let task = local.applyingExplicitFields(to: aiTask())
        #expect(task.source == local.source)
        #expect(task.source?.url == "https://github.com/o/r/pull/12")
        #expect(task.priority == .high)
        #expect(task.dueAt == nil)
        let recurring = QuickAddParser.parse("Review https://github.com/o/r/pull/12 ^fri *weekly", now: now, calendar: calendar)
        let recurringTask = recurring.applyingExplicitFields(to: aiTask())
        #expect(recurringTask.source == recurring.source)
        #expect(recurringTask.recurrence == recurring.recurrence)
        #expect(recurringTask.dueAt == recurring.dueAt)
        var original = aiTask()
        original.source = local.source
        #expect(QuickAddDraft(title: "Free text").applyingExplicitFields(to: original).source == local.source)
    }

    @Test func deletedExplicitCategoryNeverFallsBackToCollidingSlug() {
        let selected = TaskCategory(id: "selected", name: "A&S", scheduleId: "work", sortOrder: 0,
                                    createdAt: now, updatedAt: now)
        let collision = TaskCategory(id: "collision", name: "A S", scheduleId: "work", sortOrder: 1,
                                     createdAt: now, updatedAt: now)
        let inbox = TaskCategory(id: TaskCategory.inboxId, name: "Inbox", scheduleId: "work", sortOrder: 0,
                                 createdAt: now, updatedAt: now)
        #expect(QuickAddCompletion.category(explicitID: selected.id, hint: "A-S", categories: [inbox, collision, selected]) == selected)
        #expect(QuickAddCompletion.category(explicitID: selected.id, hint: "A-S", categories: [inbox, collision]) == nil)
        var tombstone = selected
        tombstone.deletedAt = now
        #expect(QuickAddCompletion.category(explicitID: selected.id, hint: "A-S", categories: [inbox, collision, tombstone]) == nil)
        #expect(QuickAddCompletion.category(explicitID: nil, hint: "A-S", categories: [inbox, collision]) == collision)
        #expect(QuickAddCompletion.category(explicitID: nil, hint: nil, categories: [inbox, collision]) == inbox)
    }
}
