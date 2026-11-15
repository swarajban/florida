import Foundation
import Testing
@testable import FloridaCore

struct DeepLinkTests {
    @Test func legacyLinksAndRoundTrips() throws {
        let links: [DeepLink] = [.agenda(), .tasks, .newTask, .settings, .agenda(day: "2028-02-29")]
        for link in links {
            #expect(DeepLink(url: link.url) == link)
        }
        #expect(DeepLink.newTask.url.absoluteString == "florida://tasks/new")
    }

    @Test func itemAliasesAndCanonicalBuilders() throws {
        let id = try #require(UUID(uuidString: "abcdef01-2345-6789-abcd-ef0123456789"))
        for host in ["task", "tasks", "project", "projects"] {
            let link: DeepLink = host.hasPrefix("task") ? .task(id) : .project(id)
            #expect(DeepLink(url: try #require(URL(string: "florida://\(host)/\(id)"))) == link)
            #expect(DeepLink(url: link.url) == link)
        }
        #expect(DeepLink.task(id).url.absoluteString == "florida://tasks/abcdef01-2345-6789-abcd-ef0123456789")
        #expect(DeepLink.project(id).url.host == "projects")
    }

    @Test func rejectsMalformedLinks() throws {
        for value in ["https://tasks", "florida://unknown", "florida://tasks/not-a-uuid",
                      "florida://projects", "florida://agenda/2027-02-29", "florida://agenda/2026-13-01",
                      "florida://agenda/2026-04-31", "florida://agenda/2026-1-01", "florida://agenda/0000-01-01"] {
            #expect(DeepLink(url: try #require(URL(string: value))) == nil)
        }
    }

    @Test func dateUsesDestinationTimeZone() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(DeepLink.agenda(day: "2026-11-15").agendaDate(timeZone: zone))
        #expect(date.ISO8601Format() == "2026-11-15T08:00:00Z")
        #expect(DeepLink.agenda().agendaDate(timeZone: zone) == nil)
    }
}
