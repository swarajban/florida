import Foundation
import Testing
@testable import FloridaCore

@Suite struct TaskSourceTests {
    @Test(arguments: [
        ("https://github.com/acme/widget/pull/123?diff=split#discussion", TaskSourceKind.github, "PR #123 in acme/widget"),
        ("https://www.github.com/acme/widget/issues/42", .github, "Issue #42 in acme/widget"),
        ("https://linear.app/acme/issue/abc-12/fix-login", .linear, "Linear ABC-12"),
        ("mailto:jane@example.com?subject=Tomorrow", .email, "jane@example.com"),
        ("https://mail.google.com/mail/u/0/#inbox/abc", .email, "mail.google.com/mail/u/0/"),
        ("https://outlook.office.com/mail/inbox/id/abc", .email, "outlook.office.com/mail/inbox/id/abc"),
        ("https://acme.slack.com/archives/C123/p456", .slack, "acme.slack.com/archives/C123/p456"),
        ("https://example.com/roadmap?date=tomorrow#work", .web, "example.com/roadmap"),
        ("https://example.com/", .web, "example.com"),
        ("https://example.com/a%20b/%23work/?query=tomorrow", .web, "example.com/a%20b/%23work/"),
        ("https://github.com/acme/widget/%70ull/123", .github, "github.com/acme/widget/%70ull/123"),
        ("https://linear.app/acme/issue/%41BC-12", .linear, "linear.app/acme/issue/%41BC-12"),
        ("https://github.com/acme//widget/pull/123", .github, "github.com/acme//widget/pull/123"),
        ("https://example.com/é", .web, "example.com/%C3%A9"),
        ("https://例.example/", .web, "xn--fsq.example"),
        ("http://[::1]/", .web, "[::1]"),
        ("http://localhost:8080/work", .web, "localhost/work"),
        ("https://github.com.evil.test/acme/widget/pull/123", .web, "github.com.evil.test/acme/widget/pull/123"),
        ("https://notlinear.app/acme/issue/ABC-12", .web, "notlinear.app/acme/issue/ABC-12"),
    ])
    func derivesKindAndShortTitle(_ text: String, _ kind: TaskSourceKind, _ title: String) throws {
        let source = try #require(TaskSource.from(url: text))
        #expect(source.kind == kind)
        #expect(source.title == title)
        #expect(source.url == text)
        #expect(source.openURL != nil)
        #expect(!source.symbolName.isEmpty)
    }

    @Test func trimsInputAndUsesSuppliedTitleWithoutFetching() throws {
        let source = try #require(TaskSource.from(url: " https://github.com/o/r/pull/1 \n", title: "  Review login fix  "))
        #expect(source.url == "https://github.com/o/r/pull/1")
        #expect(source.title == "Review login fix")
        #expect(TaskSource.from(url: source.url, title: " \n ")?.title == "PR #1 in o/r")
        let long = try #require(TaskSource.from(url: "https://example.com/" + String(repeating: "a", count: 150)))
        #expect(long.title.count == 120 && long.title.hasSuffix("…"))
        #expect(TaskSource.from(url: "https://example.com/" + String(repeating: "a", count: 4096)) == nil)
        #expect(TaskSource.from(url: source.url, title: String(repeating: "a", count: 201)) == nil)
        let unicode = try #require(TaskSource.from(url: "mailto:" + String(repeating: "😀", count: 100) + "@example.com"))
        #expect(unicode.title.utf16.count <= 120 && unicode.title.hasSuffix("…"))
    }

    @Test(arguments: [
        "javascript:alert(1)", "data:text/html,hello", "file:///etc/passwd", "ftp://example.com/file",
        "//example.com", "/relative", "https://", "https:///path", "http:example.com",
        "https://user:password@example.com/path", "https://github.com@evil.test/",
        "https://example.com/has space", "https://example.com/\\path", "https://example.com/%ZZ",
        "https://example.com/%0Aheader", "https://example.com/\u{0}bad", "mailto:", "mailto:hello",
        "mailto:@example.com", "mailto:jane@", "mailto:jane@example.com?subject=%0d%0aInjected",
        "mailto:jane%20doe@example.com", "https://example.com%20.evil.test",
        "mailto:jane%3Fsubject@example.com", "mailto:jane%23tag@example.com", "https://example.com/%C2%85",
        "https://example.com:99999/path",
    ])
    func refusesUnsafeLinksEvenWhenDecodedFromWire(_ text: String) throws {
        #expect(TaskSource.from(url: text) == nil)
        let source = TaskSource(url: text, title: "Untrusted", kind: .web)
        let decoded = try JSONDecoder().decode(TaskSource.self, from: JSONEncoder().encode(source))
        #expect(decoded.openURL == nil)
    }

    @Test func taskAndWriteAreWireCompatibleAndNilWriteClearsExplicitly() throws {
        var task = TaskItem(id: "task", categoryId: "inbox", title: "Review", durationMinutes: 30,
                            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let olderTask = try JSONCoding.encoder.encode(task)
        #expect(try JSONCoding.decoder.decode(TaskItem.self, from: olderTask).source == nil)
        task.source = TaskSource.from(url: "https://github.com/o/r/pull/123")
        #expect(try JSONCoding.decoder.decode(TaskItem.self, from: JSONCoding.encoder.encode(task)) == task)
        #expect(TaskWrite(task).source == task.source)
        var write = TaskWrite(task)
        write.source = nil
        var object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(write)) as? [String: Any])
        #expect(object["source"] is NSNull)
        object.removeValue(forKey: "source")
        let olderWrite = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONCoding.decoder.decode(TaskWrite.self, from: olderWrite).source == nil)
    }
}

@Suite struct QuickAddSourceTests {
    @Test func removingSourceForAILeavesLaterLinksAndNotesUntouched() {
        let text = "Review https://example.com and https://example.com/details // Keep https://example.com as a reference"
        #expect(QuickAddParser.removingSource(from: text) == "Review  and https://example.com/details // Keep https://example.com as a reference")
        #expect(QuickAddParser.removingSource(from: "https://example.com https://example.com") == " https://example.com")
        #expect(QuickAddParser.removingSource(from: "Review // https://example.com") == "Review // https://example.com")
        #expect(QuickAddParser.removingSource(from: "Review -- https://example.com") == "Review -- https://example.com")
    }

    private func parse(_ text: String) -> QuickAddDraft {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return QuickAddParser.parse(text, now: Date(timeIntervalSince1970: 1_794_157_200), calendar: calendar)
    }

    @Test func stripsSourceBeforeParsingOtherTokens() {
        let draft = parse("Review https://github.com/o/r/pull/123?at=3pm&due=tomorrow#work 45m #engineering tomorrow !high")
        #expect(draft.title == "Review")
        #expect(draft.source?.title == "PR #123 in o/r")
        #expect(draft.categoryHint == "engineering")
        #expect(draft.durationMinutes == 45)
        #expect(draft.priority == .high)
        #expect(draft.dueAt != nil)
        #expect(draft.pinnedStart == nil)
    }

    @Test func bareSourceGetsDerivedTitle() {
        let draft = parse("https://linear.app/acme/issue/ABC-12/fix-login")
        #expect(draft.title == "Linear ABC-12")
        #expect(draft.source?.kind == .linear)
        #expect(draft.dueAt == nil && draft.categoryHint == nil)
        #expect(parse("mailto:jane@example.com?subject=tomorrow").title == "jane@example.com")
    }

    @Test func onlyFirstSupportedURLIsExtractedAndLaterURLsStayLiteral() {
        let draft = parse("Review https://example.com/2026-11-20#work https://example.net/30m/#home/ #work")
        #expect(draft.source?.url == "https://example.com/2026-11-20#work")
        #expect(draft.title == "Review https://example.net/30m/#home/")
        #expect(draft.categoryHint == "work")
        #expect(draft.durationMinutes == nil && draft.dueAt == nil)
        let unsafe = parse("javascript:alert(1) https://example.com")
        #expect(unsafe.title == "javascript:alert(1)")
        #expect(unsafe.source?.url == "https://example.com")
    }

    @Test(arguments: ["//", "--"])
    func notesAreAnUntouchedBoundary(_ separator: String) {
        let notes = "https://github.com/o/r/pull/1 tomorrow #work 30m"
        let draft = parse("Read \(separator) \(notes)")
        #expect(draft.title == "Read")
        #expect(draft.notes == notes)
        #expect(draft.source == nil && draft.dueAt == nil && draft.categoryHint == nil)
        let withSource = parse("https://example.com \(separator) \(notes)")
        #expect(withSource.source?.url == "https://example.com")
        #expect(withSource.title == "example.com")
        #expect(withSource.notes == notes)
    }
}
