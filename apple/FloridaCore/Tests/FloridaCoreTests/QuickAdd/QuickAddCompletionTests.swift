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
        #expect(suggestions("Work #").map(\.title) == ["Inbox", "Work Engineering", "Work Infosec", "Books", "Home"])
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

    @Test func partialCategoryQueriesOfferFuzzyMatchesAndCreation() {
        func choices(_ text: String) -> [QuickAddSuggestion] {
            QuickAddCompletion.suggestions(
                in: text, caretUTF16: text.utf16.count, categories: categories, includeCategoryCreation: true)
        }
        #expect(choices("#").map(\.categoryToCreate) == [nil, nil, nil, nil, nil])
        #expect(choices("Call #wkeng").map(\.categoryId) == ["work1", nil])
        #expect(choices("Call #wkeng").last?.categoryToCreate == "wkeng")
        #expect(choices("Call #fam").map(\.categoryToCreate) == ["fam"])
        #expect(choices("Call #home").map(\.categoryId) == ["personal"])
    }

    @Test func editingOutAnAttachedHashClearsDismissalAndRetypingReopens() throws {
        var session = QuickAddCompletionSession()
        let text = "Buy#"
        let selection = NSRange(location: text.utf16.count, length: 0)
        let choice = try #require(session.suggestions(in: text, selection: selection, categories: categories).first)
        #expect(QuickAddCompletion.complete(choice, in: text)?.text == "Buy #Inbox ")
        session.dismiss(in: text, selection: selection)
        #expect(session.suggestions(in: text, selection: selection, categories: categories).isEmpty)
        session.inputChanged(to: "Buy")
        #expect(session.suggestions(in: "Buy", selection: NSRange(location: 3, length: 0), categories: categories).isEmpty)
        session.inputChanged(to: text)
        #expect(session.suggestions(in: text, selection: selection, categories: categories).map(\.categoryId)
            == ["inbox", "work1", "work2", "other", "personal"])
        #expect(suggestions("Buy#hom").map(\.categoryId) == ["personal"])
        #expect(suggestions("Work #work Buy#").isEmpty)
    }

    @Test(arguments: ["#", "!", "^", "@", "*", "=", "&"])
    func deletingTriggerDismissesImmediately(_ symbol: String) {
        let session = QuickAddCompletionSession()
        for prefix in ["", "Task ", "Atlas press page audio clips #Engineering ^today "] {
            let text = prefix + symbol
            let choices = session.suggestions(in: text, selection: NSRange(location: text.utf16.count, length: 0), categories: categories)
            if symbol != "#" || !prefix.contains("#") { #expect(!choices.isEmpty) }
            #expect(session.suggestions(in: prefix, selection: NSRange(location: prefix.utf16.count, length: 0), categories: categories).isEmpty)
            #expect(suggestions(prefix, caret: text.utf16.count).isEmpty)
        }
        #expect(suggestions("Task " + symbol + " ").isEmpty)
    }

    @Test func deletionRangesAndCaretMovementDismiss() {
        let session = QuickAddCompletionSession()
        let editing = "Task #Work-Engineering"
        #expect(!suggestions(editing).isEmpty)
        for updated in ["Task ", "", "Task Engineering"] {
            #expect(session.suggestions(in: updated, selection: NSRange(location: updated.utf16.count, length: 0), categories: categories).isEmpty)
        }
        for caret in [0, 4, 5] {
            #expect(session.suggestions(in: editing, selection: NSRange(location: caret, length: 0), categories: categories).isEmpty)
        }
        #expect(session.suggestions(in: editing, selection: NSRange(location: 5, length: 17), categories: categories).isEmpty)
        #expect(suggestions(editing + " tail").isEmpty)
    }

    @Test func escapeDismissesWithoutChangingTextAndNewTriggerReopens() {
        var session = QuickAddCompletionSession()
        let text = "Task !"
        let selection = NSRange(location: text.utf16.count, length: 0)
        #expect(!session.suggestions(in: text, selection: selection, categories: categories).isEmpty)
        session.dismiss(in: text, selection: selection)
        #expect(session.isDismissed(in: text, selection: selection))
        #expect(session.suggestions(in: text, selection: selection, categories: categories).isEmpty)
        let updated = text + " @"
        #expect(!session.suggestions(in: updated, selection: NSRange(location: updated.utf16.count, length: 0), categories: categories).isEmpty)
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

    @Test(arguments: ["^tom", "~tom", "=45", "*every 2 wee"], ["Buy milk", "👩🏽‍💻 Buy milk"])
    func completionAtTitleStartPreservesTheTitle(_ query: String, _ title: String) throws {
        let text = query + " " + title
        let choice = try #require(suggestions(text, caret: (query + " ").utf16.count).first)
        #expect(choice.replacementRange == NSRange(location: 0, length: query.utf16.count))
        let result = try #require(QuickAddCompletion.complete(choice, in: text))
        #expect(result.text == choice.replacement + " " + title)
        #expect(result.caretUTF16 == (choice.replacement + " ").utf16.count)
        #expect(QuickAddParser.parse(result.text, now: .distantPast, calendar: PacificTestCalendar.calendar).title == title)
    }

    @Test func incompleteClauseDoesNotOverwriteAWordThatOnlyStartsLikeACompletion() {
        #expect(suggestions("^next Work orders", caret: "^next W".utf16.count).isEmpty)
        #expect(suggestions("*every 2 Weekly chores", caret: "*every 2 Wee".utf16.count).isEmpty)
    }

    @Test func bareTriggerDoesNotReplaceAParsableWordBeyondItsCaret() throws {
        let text = "^ Tomorrow planning"
        let choice = try #require(suggestions(text, caret: 1).first { $0.replacement == "^fri" })
        let result = try #require(QuickAddCompletion.complete(choice, in: text))
        #expect(result.text == "^fri Tomorrow planning")
        #expect(result.caretUTF16 == "^fri ".utf16.count)
    }

    @Test func canonicallyEquivalentTextCanHaveAnIncompatibleReplacementRange() throws {
        let text = "Cafe\u{301} ^tom Buy milk"
        let updated = "Café ^tom Buy milk"
        let selection = NSRange(location: "Cafe\u{301} ^tom".utf16.count, length: 0)
        var session = QuickAddCompletionSession()
        let choice = try #require(session.suggestions(in: text, selection: selection, categories: []).first)
        #expect(QuickAddCompletion.complete(choice, in: updated) == nil)
        session.dismiss(in: text, selection: selection)
        #expect(!session.isDismissed(in: updated, selection: selection))
    }

    @Test(arguments: ["#", "@", "^", "!", "*", "=", "&", "~"])
    func insertingToolbarTriggerKeepsTitleAndCaretSeparate(_ symbol: String) throws {
        let text = "Cafe\u{301} 👩🏽‍💻 Buy milk"
        let emoji = (text as NSString).range(of: "👩🏽‍💻")
        let insideWord = NSRange(location: (text as NSString).range(of: "Buy").location + 1, length: 2)
        for (selection, prefix) in [(emoji, "Cafe\u{301} "), (insideWord, "Cafe\u{301} 👩🏽‍💻 ")] {
            let suffix = String(text.dropFirst(prefix.count))
            let result = try #require(QuickAddCompletion.insertTrigger(symbol, in: text, selection: selection))
            #expect(result.text == prefix + symbol + " " + suffix)
            #expect(result.caretUTF16 == (prefix + symbol).utf16.count)
        }
    }

    @Test func triggerInsertionReusesWhitespaceAndRejectsInvalidUTF16Selection() throws {
        let text = "Buy\tmilk"
        let result = try #require(QuickAddCompletion.insertTrigger("!", in: text, selection: NSRange(location: 3, length: 0)))
        #expect(result.text == "Buy !\tmilk")
        #expect(result.caretUTF16 == 5)
        #expect(QuickAddCompletion.insertTrigger("#", in: "😀 milk", selection: NSRange(location: 1, length: 0)) == nil)
    }

    @Test func notesToolbarTriggerKeepsTheTitleAndExistingNotes() throws {
        for text in ["Buy milk", "Buy milk //", "Buy milk -- existing note"] {
            let result = try #require(QuickAddCompletion.insertTrigger("//", in: text, selection: NSRange(location: 0, length: 0)))
            #expect(result.text == (text == "Buy milk" ? "Buy milk //" : text))
            #expect(result.caretUTF16 == result.text.utf16.count)
            #expect(QuickAddParser.parse(result.text, now: .distantPast, calendar: PacificTestCalendar.calendar).title == "Buy milk")
        }
    }

    @Test func bareCategoryTriggerOnlyMatchesAStandaloneBodyToken() throws {
        for text in ["# Buy milk", "👩🏽‍💻 # Buy milk", "Buy milk #", "Buy milk # // Notes"] {
            let range = try #require(QuickAddCompletion.bareCategoryTrigger(in: text))
            #expect(text[range] == "#")
            #expect(NSRange(range, in: text) == (text as NSString).range(of: "#"))
        }
        for text in ["Buy milk #word", "Buy milk // #", "Buy milk -- #", "C# notes"] {
            #expect(QuickAddCompletion.bareCategoryTrigger(in: text) == nil)
        }
    }

    @Test func removingBareCategoryTriggerRestoresTheCaretOutsideTheTitle() throws {
        let cases = [
            ("# Buy milk", "Buy milk", ""),
            ("👩🏽‍💻 # Buy milk", "👩🏽‍💻 Buy milk", "👩🏽‍💻 "),
            ("Buy milk #", "Buy milk", "Buy milk"),
            ("Buy milk # // Notes", "Buy milk // Notes", "Buy milk "),
        ]
        for (text, expected, prefix) in cases {
            let result = try #require(QuickAddCompletion.removeBareCategoryTrigger(in: text))
            #expect(result.text == expected)
            #expect(result.caretUTF16 == prefix.utf16.count)
        }
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
                case "^": #expect(draft.dueAt != nil || draft.someday)
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
