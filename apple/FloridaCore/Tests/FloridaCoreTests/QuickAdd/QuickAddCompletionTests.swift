import Foundation
import Testing
@testable import FloridaCore

@Suite struct QuickAddCompletionTests {
    private func category(_ id: String, _ name: String, area: CategoryArea? = nil, deleted: Bool = false) -> TaskCategory {
        TaskCategory(
            id: id, name: name, area: area, scheduleId: "schedule",
            createdAt: .distantPast, updatedAt: .distantPast, deletedAt: deleted ? .distantPast : nil)
    }

    private var categories: [TaskCategory] {
        [category("personal", "Home", area: .personal), category("work2", "Work Infosec", area: .work),
         category("other", "Books"), category("work1", "Work Engineering", area: .work),
         category("inbox", "Inbox"), category("deleted", "Work Old", area: .work, deleted: true)]
    }

    private func suggestions(_ text: String, caret: Int? = nil) -> [QuickAddSuggestion] {
        QuickAddCompletion.suggestions(in: text, caretUTF16: caret ?? text.utf16.count, categories: categories)
    }

    @Test(arguments: ["#", "@", "^", "!", "*", "=", "~", "/", "//"])
    func symbolsOpenLocalChoices(_ symbol: String) {
        let choices = suggestions("Work \(symbol)")
        #expect(!choices.isEmpty)
        #expect(choices.allSatisfy { $0.symbol == (symbol == "/" ? "//" : symbol) })
        #expect(Set(choices.map(\.id)).count == choices.count)
    }

    @Test func categoryOrderFilteringAndReplacement() throws {
        #expect(suggestions("Work #").map(\.title) == ["Inbox", "Work Engineering", "Work Infosec", "Home", "Books"])
        #expect(suggestions("Work #wOrK").map(\.categoryId) == ["work1", "work2"])
        let choice = try #require(suggestions("Work #work_eng").first)
        #expect(choice.title == "Work Engineering")
        #expect(choice.replacement == "#Work-Engineering")
        #expect(choice.replacementRange == NSRange(location: 5, length: 9))
        let result = try #require(QuickAddCompletion.complete(choice, in: "Work #work_eng"))
        #expect(result.text == "Work #Work-Engineering ")
        #expect(result.caretUTF16 == result.text.utf16.count)
        let draft = QuickAddParser.parse(result.text, now: .distantPast, calendar: PacificTestCalendar.calendar)
        #expect(draft.categoryHint == "Work-Engineering")
        #expect(draft.title == "Work")
    }

    @Test func choicesFilterEveryGrammarFamily() {
        let cases: [(String, [String])] = [
            ("@of", ["@office"]), ("^no", ["^none"]), ("^tom", ["^tomorrow"]),
            ("!2", ["!2"]), ("!hi", ["!2"]), ("!urgent", ["!1"]),
            ("*every 2 w", ["*every 2 weeks"]), ("*mon w", ["*mon wed"]),
            ("=45", ["=45m"]), ("~tom", ["~tomorrow"]), ("~next w", ["~next week"]),
        ]
        for (query, values) in cases {
            #expect(suggestions("Work \(query)").map(\.replacement) == values, "\(query)")
        }
        #expect(suggestions("Work ~").allSatisfy { $0.replacement != "~none" })
        #expect(suggestions("Work ^").contains { $0.replacement == "^none" })
        #expect(suggestions("Work ^impossible").isEmpty)
    }

    @Test func allCategoryNamesProduceConsumableTokensWithDistinctIDs() throws {
        let names = ["R&D", "A/S", "🧘", "Café", "A S", "A&S", "!?", "Work Engineering"]
        let categories = names.enumerated().map { category(String($0.offset), $0.element) }
        let choices = QuickAddCompletion.suggestions(in: "Work #", caretUTF16: 6, categories: categories)
        #expect(choices.count == names.count)
        #expect(Set(choices.map(\.id)).count == names.count)
        #expect(Set(choices.compactMap(\.categoryId)).count == names.count)
        #expect(choices.filter { $0.replacement == "#A-S" }.count == 3)
        #expect(choices.filter { $0.replacement == "#category" }.count == 2)
        for choice in choices {
            let result = try #require(QuickAddCompletion.complete(choice, in: "Work #"))
            let draft = QuickAddParser.parse(result.text, now: PacificTestCalendar.date(2026, 11, 12), calendar: PacificTestCalendar.calendar)
            #expect(draft.title == "Work", "\(choice.title)")
            #expect(draft.categoryHint != nil)
            #expect(choice.categoryId != nil)
        }
    }

    @Test func completionReplacesWholeTokenAroundCaret() throws {
        let text = "Work #work_infosec now"
        let choice = try #require(suggestions(text, caret: "Work #work_".utf16.count).first { $0.categoryId == "work1" })
        #expect(choice.replacementRange == NSRange(location: 5, length: 13))
        let result = try #require(QuickAddCompletion.complete(choice, in: text))
        #expect(result.text == "Work #Work-Engineering now")
        #expect(result.caretUTF16 == "Work #Work-Engineering ".utf16.count)
    }

    @Test func completionReplacesWholeMultiwordClauseAroundCaret() throws {
        let text = "Work *every 2 weeks #work"
        let choice = try #require(suggestions(text, caret: "Work *ev".utf16.count).first)
        #expect(choice.replacementRange == NSRange(location: 5, length: "*every 2 weeks".utf16.count))
        let result = try #require(QuickAddCompletion.complete(choice, in: text))
        #expect(result.text == text)
        #expect(result.caretUTF16 == "Work *every 2 weeks ".utf16.count)
        let date = "Work ^next week at 3pm #work"
        let tomorrow = try #require(suggestions(date, caret: "Work ^".utf16.count).first { $0.replacement == "^tomorrow" })
        #expect(QuickAddCompletion.complete(tomorrow, in: date)?.text == "Work ^tomorrow #work")
    }

    @Test func partialMultiwordQueryReplacesThroughCurrentToken() throws {
        let text = "Work *every 2 wee #work"
        let choice = try #require(suggestions(text, caret: "Work *every 2 we".utf16.count).first)
        #expect(choice.replacementRange == NSRange(location: 5, length: "*every 2 wee".utf16.count))
        #expect(QuickAddCompletion.complete(choice, in: text)?.text == "Work *every 2 weeks #work")
    }

    @Test func tokenBoundariesDoNotReopenCompletedClauses() {
        for token in ["#work", "@office", "!1", "^tomorrow", "^next week", "*weekly", "*every 2 weeks", "=45m", "~tomorrow", "//"] {
            #expect(suggestions("Work " + token + " ").isEmpty, "\(token)")
            #expect(suggestions("Work " + token + "\t").isEmpty, "\(token)")
            #expect(suggestions("Work " + token + " prose").isEmpty, "\(token)")
        }
        #expect(!suggestions("Work *every ").isEmpty)
        #expect(!suggestions("Work ^next ").isEmpty)
        #expect(suggestions("Work ^tomorrow", caret: 5).isEmpty)
        #expect(!suggestions("Work ^tomorrow", caret: 6).isEmpty)
        #expect(!suggestions("Work ^tomorrow", caret: 14).isEmpty)
    }

    @Test func usesUTF16ForEmojiAndComposedText() throws {
        let prefix = "👩🏽‍💻 Cafe\u{301} "
        let text = prefix + "@of later"
        let choice = try #require(suggestions(text, caret: (prefix + "@o").utf16.count).first)
        #expect(choice.replacementRange == NSRange(location: prefix.utf16.count, length: 3))
        let result = try #require(QuickAddCompletion.complete(choice, in: text))
        #expect(result.text == prefix + "@office later")
        #expect(result.caretUTF16 == (prefix + "@office ").utf16.count)
    }

    @Test func invalidOffsetsAndStaleSuggestionsAreRejected() throws {
        let text = "😀 #w"
        #expect(suggestions(text, caret: -1).isEmpty)
        #expect(suggestions(text, caret: 1).isEmpty)
        #expect(suggestions(text, caret: text.utf16.count + 1).isEmpty)
        #expect(suggestions(text, caret: Int.max).isEmpty)
        let choice = try #require(suggestions(text).first)
        #expect(QuickAddCompletion.complete(choice, in: "😀 #wo") == nil)
        #expect(QuickAddCompletion.complete(choice, in: "Other #w") == nil)
    }

    @Test func noCompletionInURLsWordsOrNotes() {
        for text in ["Work https://example.com/#wo", "Work https://example.com/^", "Work https://example.com//", "Work person@of", "Work word^tom", "Work C#", "Work foo=4", "Work path/to/", "Work /tmp", "Work // ^tom", "Work -- #wo", "Work // ", "Work #work later"] {
            #expect(suggestions(text).isEmpty, "\(text)")
        }
        let text = "Work ^tom // #work"
        #expect(!suggestions(text, caret: "Work ^tom".utf16.count).isEmpty)
    }

    @Test func laterLiteralCategoryTokensNeverOfferCompletion() {
        for text in ["Work #work #", "Work #work #ho", "Work #unknown #wo", "Work # #wo"] {
            #expect(suggestions(text).isEmpty, "\(text)")
        }
        #expect(!suggestions("Work ^fri #wo").isEmpty)
        let text = "Work #wo #literal"
        #expect(suggestions(text, caret: "Work #wo".utf16.count).map(\.categoryId) == ["work1", "work2"])
    }

    @Test func attachedNotesAreOpaqueAtEveryCaretPosition() {
        let text = "Work //Check ^tom #work @office *weekly"
        for caret in ("Work //C".utf16.count)...text.utf16.count {
            #expect(suggestions(text, caret: caret).isEmpty)
        }
        #expect(suggestions("Work //^tom").isEmpty)
        #expect(suggestions("Work //Check #").isEmpty)
        #expect(!suggestions("Work https://example.com//notes ^tom").isEmpty)
        #expect(!suggestions("Work f//notes ^tom").isEmpty)
    }

    @Test func notesCompletionStartsOpaqueNotesAndReusesWhitespace() throws {
        for suffix in ["", " existing note", "\nexisting note"] {
            let text = "Work //" + suffix
            let choice = try #require(suggestions(text, caret: "Work //".utf16.count).first)
            let result = try #require(QuickAddCompletion.complete(choice, in: text))
            #expect(result.text == "Work //" + (suffix.isEmpty ? " " : suffix))
            #expect(result.caretUTF16 == "Work // ".utf16.count)
        }
    }

    @Test func everyPresetCompletionParses() throws {
        for symbol in ["^", "@", "!", "*", "=", "~"] {
            for choice in suggestions("Work " + symbol) {
                let result = try #require(QuickAddCompletion.complete(choice, in: "Work " + symbol))
                let draft = QuickAddParser.parse(result.text, now: PacificTestCalendar.date(2026, 11, 12), calendar: PacificTestCalendar.calendar)
                #expect(draft.title == "Work", "\(result.text)")
                switch symbol {
                case "^": #expect(draft.dueAt != nil || draft.dueDateNotNeeded)
                case "@": #expect(draft.context != nil)
                case "!": #expect(draft.priority != nil)
                case "*": #expect(draft.recurrence != nil)
                case "=": #expect(draft.durationMinutes != nil)
                case "~": #expect(draft.startAt != nil)
                default: Issue.record("Unexpected symbol")
                }
            }
        }
    }
}
