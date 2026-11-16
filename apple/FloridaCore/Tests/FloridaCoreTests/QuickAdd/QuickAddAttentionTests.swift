import Foundation
import Testing
@testable import FloridaCore

@Suite struct QuickAddAttentionTests {
    private func parse(_ text: String) -> QuickAddDraft {
        QuickAddParser.parse(text, now: .distantPast, calendar: PacificTestCalendar.calendar)
    }

    @Test(arguments: ["&parallel", "&shared", "&alongside", "&PARALLEL"])
    func parallelAliases(_ token: String) {
        #expect(parse("Task " + token).attention == .shared)
        #expect(parse(token + " Task").title == "Task")
    }

    @Test(arguments: ["&full", "&focus", "&FULL"])
    func fullAliases(_ token: String) {
        #expect(parse("Task " + token).attention == .full)
        #expect(parse(token + " Task").title == "Task")
    }

    @Test func attentionPreservesURLsNotesAndLiteralAmpersands() {
        for text in ["https://example.com?a=1&b=2", "Task&full", "Task &unknown", "Task // &parallel"] {
            #expect(parse(text).attention == nil)
        }
        let draft = parse("Task https://example.com?a=1&b=2 &shared")
        #expect(draft.source?.url == "https://example.com?a=1&b=2")
        #expect(draft.attention == .shared)
        #expect(parse("Task &full &shared").title == "Task &shared")
    }

    @Test func attentionCompletionsAndDeletion() throws {
        let session = QuickAddCompletionSession()
        let text = "Task &"
        let choices = session.suggestions(in: text, selection: NSRange(location: text.utf16.count, length: 0), categories: [])
        #expect(choices.map(\.replacement) == ["&parallel", "&full"])
        for choice in choices {
            let result = try #require(QuickAddCompletion.complete(choice, in: text))
            #expect(parse(result.text).attention == (choice.id == "&parallel" ? .shared : .full))
        }
        #expect(session.suggestions(in: "Task ", selection: NSRange(location: 5, length: 0), categories: []).isEmpty)
        #expect(QuickAddCompletion.suggestions(in: "Task&", caretUTF16: 5, categories: []).isEmpty)
    }

    @Test func attentionChipCyclesWithoutTouchingNotesOrURLs() {
        let text = "Task https://example.com?a=1&b=2 // &full stays literal"
        let parallel = QuickAddParser.cyclingAttention(in: text, current: nil)
        #expect(parse(parallel).attention == .shared)
        let full = QuickAddParser.cyclingAttention(in: parallel, current: .shared)
        #expect(parse(full).attention == .full)
        let inherited = QuickAddParser.cyclingAttention(in: full, current: .full)
        #expect(parse(inherited).attention == nil)
        for updated in [parallel, full, inherited] {
            #expect(parse(updated).source == parse(text).source)
            #expect(parse(updated).notes == "&full stays literal")
        }
        #expect(QuickAddParser.cyclingAttention(in: "&full", current: .full).isEmpty)
    }

    @Test func explicitAttentionSurvivesReview() {
        let task = TaskItem(id: "task", categoryId: "inbox", title: "AI", durationMinutes: 30,
                            createdAt: .distantPast, updatedAt: .distantPast)
        #expect(parse("Task &parallel").applyingExplicitFields(to: task).attention == .shared)
        #expect(parse("Task &full").applyingExplicitFields(to: task).attention == .full)
    }
}
