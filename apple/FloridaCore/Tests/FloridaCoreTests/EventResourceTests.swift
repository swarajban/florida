import Foundation
import Testing
@testable import FloridaCore

struct EventResourceTests {
    @Test func extractsPlainTextAndLocationInStableOrder() {
        let resources = EventResource.extract(
            description: "Read https://github.com/florida/calendar/pull/12 and www.example.com/brief.",
            location: "Room 4: https://linear.app/team/issue/FLOR-21/resources")
        #expect(resources.map(\.kind) == [.github, .other, .linear])
        #expect(resources.map(\.title) == ["florida/calendar", "example.com", "FLOR-21"])
        #expect(resources.map(\.url.absoluteString) == [
            "https://github.com/florida/calendar/pull/12", "https://www.example.com/brief",
            "https://linear.app/team/issue/FLOR-21/resources",
        ])
    }

    @Test func readsGoogleHTMLAndDecodesEntitiesOnce() {
        let resources = EventResource.extract(description: """
            <p><a target="_blank" href="https://docs.google.com/document/d/abc?x=1&amp;y=2"><b>Prep</b> &amp; Q&#38;A &#x2014; &#39;review&#39;</a></p>
            <A HREF='https://notion.so/brief'>Team&nbsp;notes &lt;draft&gt;</A><br>
            https://example.com/one&#160;https://example.com/two&nbsp;
            <a href=https://figma.com/design/id/Project-Review>Design &amp;lt;v2&amp;gt;</a>
            """, location: nil)
        #expect(resources.count == 5)
        #expect(resources[0].title == "Prep & Q&A — 'review'")
        #expect(resources[0].url.absoluteString == "https://docs.google.com/document/d/abc?x=1&y=2")
        #expect(resources[1].title == "Team notes <draft>")
        #expect(resources[2].url.absoluteString == "https://example.com/one")
        #expect(resources[3].url.absoluteString == "https://example.com/two")
        #expect(resources[4].title == "Design &lt;v2&gt;")
    }

    @Test func unwrapsGoogleRedirectsAndLeavesTargetTrackingIntact() {
        let target = "https://docs.google.com/document/d/abc?utm_source=calendar&resourcekey=secret#heading"
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let resources = EventResource.extract(description: """
            <a href="https://www.google.com/url?q=\(encoded)&amp;sa=D&amp;source=calendar">Planning doc</a>
            https://google.com/url?url=\(encoded)
            """, location: nil)
        #expect(resources.count == 1)
        #expect(resources.first?.url.absoluteString == target)
        #expect(resources.first?.title == "Planning doc")
    }

    @Test func excludesTheJoinTargetAndKeepsOtherConferenceLinks() {
        let event = CalendarEvent(
            id: "event", calendarId: "cal", googleId: "google",
            location: "https://zoom.us/j/backup",
            description: """
                <a href="https://www.google.com/url?q=https%3A%2F%2Fmeet.google.com%2Fprimary">Join</a>
                https://meet.google.com/extra https://docs.google.com/document/d/abc
                """,
            conferenceUrl: "https://meet.google.com/primary", updatedAt: Date(timeIntervalSince1970: 0))
        #expect(event.resources.map(\.kind) == [.googleMeet, .googleDocs, .zoom])
        #expect(event.resources.map(\.url.absoluteString).contains("https://meet.google.com/primary") == false)
        let escaped = EventResource.extract(
            description: "https://zoom.us/j/123?pwd=a&amp;b=2", location: nil,
            excluding: URL(string: "https://zoom.us/j/123?pwd=a&amp;b=2"))
        #expect(escaped.isEmpty)
    }

    @Test func deduplicatesAndPrefersAnchorTitlesWithoutRemovingQueryParameters() {
        let resources = EventResource.extract(description: """
            https://EXAMPLE.com:443/doc
            <a href="https://example.com/doc">Readable title</a>
            https://example.com/doc?utm_source=a https://example.com/doc?utm_source=b
            """, location: "https://example.com/doc")
        #expect(resources.count == 3)
        #expect(resources[0].title == "Readable title")
        #expect(resources[1].url.query == "utm_source=a")
        #expect(resources[2].url.query == "utm_source=b")
    }

    @Test func removesProsePunctuationButPreservesBalancedParenthesesAndAnchorTargets() {
        let resources = EventResource.extract(description: """
            (https://example.com/a). [https://example.com/b], https://example.com/wiki/Thing_(detail).
            <a href="https://example.com/exact!">Exact</a>
            """, location: nil)
        #expect(resources.map(\.url.absoluteString) == [
            "https://example.com/a", "https://example.com/b", "https://example.com/wiki/Thing_(detail)",
            "https://example.com/exact!",
        ])
    }

    @Test func identifiesKindsWithoutTrustingLookalikeHosts() {
        let resources = EventResource.extract(description: """
            https://docs.google.com/document/d/1 https://docs.google.com/spreadsheets/d/1
            https://docs.google.com/presentation/d/1 https://workspace.notion.site/notes
            https://figma.com/design/abc/Design-Review https://github.com/team/repo
            https://linear.app/team/issue/ABC-1/title https://us02web.zoom.us/j/123
            https://meet.google.com/abc-defg-hij https://notgithub.com/team/repo
            https://notion.so.evil.test/notes
            """, location: nil)
        #expect(resources.map(\.kind) == [
            .googleDocs, .googleSheets, .googleSlides, .notion, .figma, .github, .linear, .zoom, .googleMeet, .other, .other,
        ])
        #expect(resources[4].title == "Design Review")
        #expect(resources[9].kindLabel == "notgithub.com")
    }

    @Test func ignoresUnsupportedSchemesMalformedLinksAndHTMLAttributes() {
        let resources = EventResource.extract(description: """
            <img src="https://example.com/tracker">
            <a href="javascript:alert(1)">Unsafe</a><a href="mailto:person@example.com">Email</a>
            <a href="https://user:password@example.com">Credentials</a>
            <a href="https://">Missing host</a><a href="/relative">Relative</a>
            """, location: "Room 7")
        #expect(resources.isEmpty)
        #expect(EventResource.extract(description: nil, location: nil).isEmpty)
    }

    @Test func supportsAngleBracketURLsWithoutTreatingThemAsHTMLTags() {
        let resources = EventResource.extract(description: "See <https://example.com/brief>.", location: nil)
        #expect(resources.first?.url.absoluteString == "https://example.com/brief")
    }

    @Test func readsHrefRatherThanSimilarlyNamedAttributes() {
        let resources = EventResource.extract(description: """
            <a data-href="https://example.com/not-target" href="https://example.com/target">Brief</a>
            """, location: nil)
        #expect(resources.map(\.url.absoluteString) == ["https://example.com/target"])
    }

    @Test func fallsBackFromURLAnchorLabelsAndBoundsLongTitles() {
        let resources = EventResource.extract(description: """
            <a href="https://docs.google.com/document/d/abc">https://docs.google.com/document/d/abc</a>
            <a href="https://example.com">\(String(repeating: "Long title ", count: 20))</a>
            """, location: nil)
        #expect(resources[0].title == "Google Docs")
        #expect(resources[1].title.count == 56)
        #expect(resources[1].title.hasSuffix("…"))
    }
}
