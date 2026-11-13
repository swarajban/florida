import Foundation
import Testing
@testable import FloridaCore

@Suite struct TaskTriageTests {
    func task() -> TaskItem {
        TaskItem(id: "t1", categoryId: "work", title: "Review", durationMinutes: 30,
                 createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func legacyTaskDefaultsToAnUndecidedDate() throws {
        let original = task()
        #expect(!original.someday)
        var object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(original)) as? [String: Any])
        object.removeValue(forKey: "someday")
        let decoded = try JSONCoding.decoder.decode(TaskItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == original)
        #expect(decoded.needsTriage)
    }

    @Test(arguments: [false, true], [false, true])
    func triageRequiresBothCategoryAndDateDecision(inbox: Bool, notNeeded: Bool) {
        for mask in 0..<8 {
            var value = task()
            value.categoryId = inbox ? TaskCategory.inboxId : "work"
            value.dueAt = mask & 1 != 0 ? Date(timeIntervalSince1970: 100) : nil
            value.startAt = mask & 2 != 0 ? Date(timeIntervalSince1970: 200) : nil
            value.pinnedStart = mask & 4 != 0 ? Date(timeIntervalSince1970: 300) : nil
            value.someday = notNeeded
            #expect(value.needsTriage == (inbox || (mask == 0 && !notNeeded)))
            #expect(value.dateForTaskList()?.date == (notNeeded ? nil : value.dueAt ?? value.pinnedStart ?? value.startAt))
        }
    }

    @Test func listDateUsesDueThenPinThenStartWithoutCallingUndatedTasksSomeday() {
        var value = task()
        let start = Date(timeIntervalSince1970: 100)
        let pin = Date(timeIntervalSince1970: 200)
        let due = Date(timeIntervalSince1970: 300)
        #expect(value.dateForTaskList() == nil)
        #expect(value.needsTriage && !value.someday)
        value.startAt = start
        #expect(value.dateForTaskList() == .start(start))
        #expect(!value.needsTriage && !value.someday)
        value.pinnedStart = pin
        #expect(value.dateForTaskList() == .pinned(pin))
        value.dueAt = due
        #expect(value.dateForTaskList() == .due(due))
        value.someday = true
        #expect(value.dateForTaskList() == nil)
        value.dueAt = nil
        value.pinnedStart = nil
        #expect(value.dateForTaskList() == nil)
        value.someday = false
        #expect(value.dateForTaskList() == .start(start))
    }

    @Test func triageChipContractSeparatesMissingCategoryFromMissingDateDecision() {
        var value = task()
        #expect(value.needsTriage && value.categoryId != TaskCategory.inboxId)
        #expect(value.dateForTaskList() == nil && !value.someday)
        value.categoryId = TaskCategory.inboxId
        value.someday = true
        #expect(value.needsTriage && value.dateForTaskList() == nil)
        value.categoryId = "work"
        #expect(!value.needsTriage && value.someday)
        value.someday = false
        value.startAt = Date(timeIntervalSince1970: 100)
        #expect(!value.needsTriage && value.dateForTaskList() == .start(value.startAt!))
        value.categoryId = TaskCategory.inboxId
        #expect(value.needsTriage && value.dateForTaskList() == .start(value.startAt!))
    }

    @Test(arguments: [false, true])
    func taskAndWriteRoundTripExplicitDateDecision(notNeeded: Bool) throws {
        var value = task()
        value.someday = notNeeded
        let taskData = try JSONCoding.encoder.encode(value)
        #expect(try JSONCoding.decoder.decode(TaskItem.self, from: taskData) == value)
        let taskObject = try #require(JSONSerialization.jsonObject(with: taskData) as? [String: Any])
        #expect(taskObject["someday"] as? Bool == notNeeded)
        let write = TaskWrite(value)
        let data = try JSONCoding.encoder.encode(write)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["someday"] as? Bool == notNeeded)
        #expect(try JSONCoding.decoder.decode(TaskWrite.self, from: data) == write)
    }

    @Test func legacyWriteRetainsAnOmittedDecision() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(TaskWrite(task()))) as? [String: Any])
        object.removeValue(forKey: "someday")
        let legacy = try JSONCoding.decoder.decode(TaskWrite.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.someday == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(legacy)) as? [String: Any])
        #expect(encoded["someday"] == nil)
    }

    @Test func quickAddNoDateFormsAreExplicitAndBoundaryAware() {
        let now = Date(timeIntervalSince1970: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for phrase in ["^none", "someday", "SOMEDAY", "^someday", "^ SOMEDAY"] {
            let draft = QuickAddParser.parse("Review #work \(phrase)", now: now, calendar: calendar)
            #expect(draft.title == "Review")
            #expect(draft.categoryHint == "work")
            #expect(draft.someday)
            let result = draft.applyingExplicitFields(to: task(), categoryId: "work")
            #expect(result.someday)
            #expect(!result.needsTriage)
            var unfiled = result
            unfiled.categoryId = TaskCategory.inboxId
            #expect(unfiled.needsTriage)
        }
        let literal = QuickAddParser.parse("Review nodue somedayish https://example.com/someday", now: now, calendar: calendar)
        #expect(!literal.someday)
        #expect(literal.title == "Review nodue somedayish")
        #expect(literal.source == TaskSource.from(url: "https://example.com/someday"))
        let dated = QuickAddParser.parse("Review ^tomorrow nodue", now: now, calendar: calendar)
        #expect(!dated.someday)
        #expect(dated.title == "Review nodue")
        let decided = QuickAddParser.parse("Review nodue ^tomorrow", now: now, calendar: calendar)
        #expect(decided.dueAt != nil)
        #expect(decided.title == "Review nodue")
    }

    @Test func recurringNoDateDecisionSurvivesDirectDetailsAndAIStylePreparation() {
        let now = Date(timeIntervalSince1970: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let draft = QuickAddParser.parse("Review #work *weekly ^none", now: now, calendar: calendar)
        var direct = task()
        direct.recurrence = draft.recurrence
        direct.someday = draft.someday
        direct.prepareToEnableRecurrence()
        var details = direct
        details.title = "Edited title"
        let reviewed = draft.applyingExplicitFields(to: task(), categoryId: "work")
        #expect(direct.dueAt == nil && direct.someday)
        #expect(details.dueAt == direct.dueAt && details.someday)
        #expect(reviewed.dueAt == direct.dueAt && reviewed.someday)
        #expect(direct.startAt == nil && reviewed.startAt == nil)
        #expect(!direct.needsTriage && !details.needsTriage && !reviewed.needsTriage)
    }

    @Test func crossFieldDateDecisionsFollowInputOrder() {
        let now = PacificTestCalendar.date(2026, 11, 12, 10)
        let calendar = PacificTestCalendar.calendar
        for phrase in ["^none", "^someday", "someday"] {
            for dated in ["^fri", "due fri", "tomorrow", "~fri", "after fri", "at 3pm"] {
                let paused = QuickAddParser.parse("Review \(dated) \(phrase)", now: now, calendar: calendar)
                #expect(paused.someday && paused.dueAt == nil && paused.pinnedStart == nil)
                #expect(paused.title == "Review")
                let active = QuickAddParser.parse("Review \(phrase) \(dated)", now: now, calendar: calendar)
                #expect(!active.someday)
                #expect(active.dueAt != nil || active.startAt != nil || active.pinnedStart != nil)
                #expect(active.title == "Review")
                var original = task()
                original.dueAt = now
                original.pinnedStart = now
                original.startAt = now
                let applied = active.applyingExplicitFields(to: original)
                #expect(!applied.someday)
                #expect(applied.dueAt == active.dueAt && applied.pinnedStart == active.pinnedStart)
                #expect(applied.startAt == (active.startAt ?? original.startAt))
            }
        }
        let start = QuickAddParser.parse("Review ~today someday", now: now, calendar: calendar)
        #expect(start.startAt == calendar.startOfDay(for: now))
        #expect(start.someday)
        let resumed = QuickAddParser.parse("Review ~today someday ~tomorrow", now: now, calendar: calendar)
        #expect(resumed.startAt == PacificTestCalendar.date(2026, 11, 13))
        #expect(!resumed.someday && resumed.title == "Review")
    }

    @Test func explicitDraftFieldsNormalizeSomedayWithoutResettingUnrelatedEdits() {
        let date = Date(timeIntervalSince1970: 100)
        for mask in 0..<8 {
            var original = task()
            original.dueAt = mask & 1 != 0 ? date : nil
            original.startAt = mask & 2 != 0 ? date : nil
            original.pinnedStart = mask & 4 != 0 ? date : nil
            let paused = QuickAddDraft(someday: true).applyingExplicitFields(to: original)
            #expect(paused.someday && paused.dueAt == nil && paused.pinnedStart == nil)
            #expect(paused.startAt == original.startAt)
            #expect(QuickAddDraft(notes: "Unrelated").applyingExplicitFields(to: paused).someday)
            for draft in [QuickAddDraft(dueAt: date), QuickAddDraft(startAt: date), QuickAddDraft(pinnedStart: date)] {
                #expect(!draft.applyingExplicitFields(to: paused).someday)
            }
        }
    }
}
