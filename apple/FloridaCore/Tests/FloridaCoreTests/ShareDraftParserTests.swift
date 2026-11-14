import Foundation
import Testing
@testable import FloridaCore

@Suite struct ShareDraftParserTests {
    let now = JSONCoding.parseInstant("2026-11-13T17:00:00Z")!
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    @Test func urlOnlyUsesExistingSourceDerivationWithoutParsingTheDerivedTitle() throws {
        let url = "https://github.com/owner/repo/pull/123"
        let draft = try #require(ShareDraftParser.parse(ShareInput(url: url), now: now, calendar: calendar))
        #expect(draft.source == TaskSource.from(url: url))
        #expect(draft.title == "PR #123 in owner/repo")
        #expect(draft.categoryHint == nil)
        #expect(draft.durationMinutes == nil)
    }

    @Test func pageTitleWinsAndQuickAddGrammarIsReused() throws {
        let draft = try #require(ShareDraftParser.parse(ShareInput(
            url: "https://example.com/article", pageTitle: "Review 45m tomorrow #work", text: "Ignored host text"),
            now: now, calendar: calendar))
        #expect(draft.title == "Review")
        #expect(draft.durationMinutes == 45)
        #expect(draft.categoryHint == "work")
        #expect(draft.dueAt == JSONCoding.parseInstant("2026-11-15T01:00:00Z"))
        #expect(draft.source?.title == "Review 45m tomorrow #work")
    }

    @Test func textWithLinksKeepsTheFirstSupportedSource() throws {
        let text = "Read file:///private https://linear.app/team/issue/APP-12 https://example.com/second"
        let draft = try #require(ShareDraftParser.parse(ShareInput(text: text), now: now, calendar: calendar))
        #expect(draft.source == TaskSource.from(url: "https://linear.app/team/issue/APP-12"))
        #expect(draft.title.contains("https://example.com/second"))
        #expect(!draft.title.contains("https://linear.app"))
    }

    @Test func explicitSourceDoesNotConsumeADifferentInlineLink() throws {
        let draft = try #require(ShareDraftParser.parse(ShareInput(
            url: "https://example.com/main", text: "Read https://example.org/reference"), now: now, calendar: calendar))
        #expect(draft.source?.url == "https://example.com/main")
        #expect(draft.title == "Read https://example.org/reference")
    }

    @Test func shortTextWithoutALinkIsTheTitle() throws {
        let text = "Buy groceries"
        let draft = try #require(ShareDraftParser.parse(ShareInput(text: text), now: now, calendar: calendar))
        #expect(draft.title == text)
        #expect(draft.source == nil)
        #expect(draft.notes == nil)
    }

    @Test func entirelyConsumedGrammarStillHasASharedTitle() throws {
        let draft = try #require(ShareDraftParser.parse(ShareInput(text: "Tomorrow"), now: now, calendar: calendar))
        #expect(draft.title == "Tomorrow")
        #expect(draft.dueAt != nil)
    }

    @Test func multilineTextPreservesNotesAndFindsTheirLink() throws {
        let notes = "Read this background\nhttps://example.com/article"
        let draft = try #require(ShareDraftParser.parse(ShareInput(text: "Review 30m\n" + notes), now: now, calendar: calendar))
        #expect(draft.title == "Review")
        #expect(draft.durationMinutes == 30)
        #expect(draft.notes == notes)
        #expect(draft.source?.url == "https://example.com/article")
    }

    @Test func longSingleLineKeepsAllTextInNotes() throws {
        let text = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let draft = try #require(ShareDraftParser.parse(ShareInput(text: text), now: now, calendar: calendar))
        #expect(draft.title.count <= 120)
        #expect(draft.notes == text)
    }

    @Test(arguments: [ShareInput(), ShareInput(url: "file:///private"), ShareInput(text: " \n "), ShareInput(pageTitle: "Image")])
    func unsupportedInputReturnsNothing(_ input: ShareInput) {
        #expect(ShareDraftParser.parse(input, now: now, calendar: calendar) == nil)
    }

    @Test func invalidExplicitURLDoesNotHideSupportedText() throws {
        let draft = try #require(ShareDraftParser.parse(ShareInput(
            url: "javascript:alert(1)", text: "Read https://example.com"), now: now, calendar: calendar))
        #expect(draft.title == "Read")
        #expect(draft.source?.url == "https://example.com")
    }
}
