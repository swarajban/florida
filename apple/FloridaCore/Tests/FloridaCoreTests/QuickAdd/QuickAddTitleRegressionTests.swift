import Foundation
import Testing
@testable import FloridaCore

@Suite struct QuickAddTitleRegressionTests {
    private let now = Date(timeIntervalSince1970: 1_795_314_900)
    private var calendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    @Test(arguments: ["Q", "Quivella", "Quivella s", "Quivella screening"])
    func eventPreviewReparseAndSaveKeepTheWholeTitle(_ title: String) {
        let template = CalendarEvent(id: "new", calendarId: "personal", googleId: "",
            startAt: now, endAt: now.addingTimeInterval(1800), updatedAt: now)
        let calendars = [CalendarInfo(id: "personal", accountId: "account", googleId: "personal",
            summary: "Personal", accessRole: "owner", selected: true, updatedAt: now)]
        let accounts = [GoogleAccount(id: "account", email: "test@example.com", label: "personal", updatedAt: now)]
        var session = EventQuickAddSession(event: template, now: now, calendar: calendar)

        session.updateText(NSMutableString(string: title) as String)
        #expect(session.draft.title == title)
        #expect(session.draft.startAt == now)
        let dated = NSMutableString(string: " — \(title) on 12/16 at 6pm — ") as String
        let parsed = EventQuickAddParser.parse(dated, now: now, calendar: calendar)
        let start = calendar.date(from: DateComponents(year: 2026, month: 12, day: 16, hour: 18))
        #expect(parsed.title == title)
        #expect(parsed.startAt == start)

        session.setTitle("  \(title)  ")
        session.updateText(dated)
        #expect(session.event(in: calendars, accounts: accounts)?.summary == title)
        session.resetCorrections()
        #expect(session.draft.title == title)
        #expect(session.event(in: calendars, accounts: accounts)?.summary == title)
    }

    @Test(arguments: ["Q", "Quivella", "Quivella s", "Quivella screening"])
    func shareAndTaskSymbolsKeepTheWholeTitle(_ title: String) {
        let bridge = NSMutableString(string: "  \(title)\nNotes  ") as String
        let shared = ShareDraftParser.parse(ShareInput(text: bridge), now: now, calendar: calendar)
        #expect(shared?.title == title)
        #expect(shared?.notes == "Notes")

        let pageTitle = NSMutableString(string: "  \(title)  ") as String
        let page = ShareDraftParser.parse(ShareInput(url: "https://example.com/story", pageTitle: pageTitle),
            now: now, calendar: calendar)
        #expect(page?.title == title)
        #expect(page?.source?.title == title)

        for clause in ["=30m", "= 30m"] {
            let raw = NSMutableString(string: "— \(title) \(clause) —") as String
            let task = QuickAddParser.parse(raw, now: now, calendar: calendar)
            #expect(task.title == title)
            #expect(task.durationMinutes == 30)
        }
    }

    @Test func trimsTitleEdgesWithoutChangingTheLiteralText() {
        let title = "e\u{301}  🌱 — /~"
        #expect(TitleText.trimmingWhitespace("\u{200B}\u{00A0}\t\(title)\r\n\u{200B}") == title)
        #expect(TitleText.trimmingWhitespace("\t\n\u{200B}").isEmpty)
        #expect(QuickAddScanner.joinTitle(["—", "Quivella", "https://example.com/a/"]) == "Quivella https://example.com/a/")
        #expect(QuickAddScanner.joinTitle(["—", ":", "~"]).isEmpty)
    }
}
