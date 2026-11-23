import Foundation
import Testing
@testable import FloridaCore

@Suite struct LaterPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_762_344_000)

    private func item(_ id: String, action: LaterItem.Action = .later, at date: Date? = nil) -> LaterItem {
        var item = LaterItem(id: id, url: "https://example.com", canonicalUrl: "https://example.com",
            title: id, site: "example.com", kind: .article, savedAt: now, source: .share, updatedAt: now)
        item.apply(action, at: date ?? now)
        return item
    }

    @Test func groupsLiveItemsAndCountsThisMonthsArchives() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var deleted = item("deleted", action: .archive)
        deleted.deletedAt = now
        let older = item("older", action: .archive, at: calendar.date(byAdding: .month, value: -1, to: now))
        let later = LaterPresentation(items: [item("queued"), item("done", action: .read),
            item("archived", action: .archive), older, deleted])
        #expect(later.items(in: .queue).map(\.id) == ["queued"])
        #expect(later.items(in: .read).map(\.id) == ["done"])
        #expect(later.items(in: .archived).map(\.id) == ["archived", "older"])
        #expect(later.archivedThisMonth(at: now, calendar: calendar) == "1 archived this month")
        #expect(LaterItem.Status.allCases.map(\.laterDisplayTitle) == ["Queue", "Read", "Archived"])
    }

    @Test func catchUpUsesPlanOrderButDoesNotOfferItemsAlreadyRead() {
        let later = LaterPresentation(items: [item("first"), item("second"), item("done", action: .read)])
        let block = CatchUpBlock(id: "block", startAt: now, endAt: now.addingTimeInterval(600),
            items: ["second", "done", "first"].map {
                CatchUpBlock.Item(id: $0, title: $0, site: "example.com", url: "https://example.com", estMinutes: 5)
            })
        #expect(block.laterDisplayTitle == "Catch up · 3")
        #expect(later.items(in: block).map(\.id) == ["second", "first"])
        #expect(later.items(in: block).map(\.laterEstimateLabel) == ["5 min", "5 min"])
    }

    @Test func onlyPromptsOncePerVisitAndOnlyIfStillQueued() {
        let queued = item("queued")
        let later = LaterPresentation(items: [queued])
        var visit = LaterVisit()
        visit.open(queued)
        #expect(visit.finish(in: later) == queued)
        #expect(visit.finish(in: later) == nil)
        visit.open(queued)
        #expect(visit.finish(in: LaterPresentation(items: [item("queued", action: .read)])) == nil)
        visit.open(item("queued", action: .archive))
        #expect(visit.finish(in: later) == nil)
    }
}
