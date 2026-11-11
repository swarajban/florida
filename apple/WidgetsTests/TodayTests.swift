import FloridaKit
import Foundation
import Testing

struct TodayTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    @Test func remainingAgendaStopsAtTodayAndUpdatesAtBoundaries() throws {
        let now = instant("2026-11-11T00:00:00Z") // 4 PM in LA, not Nov 11 locally.
        let day = calendar.startOfDay(for: now)
        let allDay = block("All day", "2026-11-10T00:00:00Z", "2026-11-11T00:00:00Z", allDay: true)
        let ended = block("Ended", "2026-11-10T23:00:00Z", "2026-11-11T00:00:00Z")
        let current = block("Current", "2026-11-10T23:30:00Z", "2026-11-11T00:30:00Z")
        var task = block("Scheduled task", "2026-11-11T01:00:00Z", "2026-11-11T02:00:00Z")
        task.kind = .task
        let tomorrow = block("Tomorrow", "2026-11-11T08:00:00Z", "2026-11-11T09:00:00Z")
        let loaded = [tomorrow, task, ended, allDay, current]
        let entry = TodayProvider.entry(at: now, day: day, from: loaded, calendar: calendar)
        #expect(entry.blocks.map(\.title) == ["All day", "Current", "Scheduled task"])
        let timeline = TodayProvider.timeline(at: now, from: loaded, calendar: calendar)
        let afterEnd = try #require(timeline.entries.first { $0.date == current.end })
        #expect(afterEnd.blocks.map(\.title) == ["All day", "Scheduled task"])
        let atStart = try #require(timeline.entries.first { $0.date == task.start })
        #expect(atStart.blocks.last?.isInProgress(at: atStart.date) == true)
        #expect(TodayProvider.entry(at: now, day: day, from: [], calendar: calendar).available)
        #expect(!TodayProvider.entry(at: now, day: day, from: nil, calendar: calendar).available)
    }

    @Test func midnightClearsYesterdayIncludingAllDayAndOvernightEvents() throws {
        // The fall DST day is 25 hours long. Midnight must be calendar-based, not +24 hours.
        let now = instant("2026-11-02T07:50:00Z")
        let loaded = [
            block("All day", "2026-11-01T00:00:00Z", "2026-11-02T00:00:00Z", allDay: true),
            block("Overnight", "2026-11-02T07:00:00Z", "2026-11-02T10:00:00Z"),
        ]
        let timeline = TodayProvider.timeline(at: now, from: loaded, calendar: calendar)
        #expect(timeline.entries.first?.blocks.count == 2)
        let last = try #require(timeline.entries.last)
        #expect(last.date == instant("2026-11-02T08:00:00Z"))
        #expect(last.day == last.date)
        #expect(last.blocks.isEmpty)
    }

    private func instant(_ text: String) -> Date { JSONCoding.parseInstant(text)! }

    private func block(_ title: String, _ start: String, _ end: String, allDay: Bool = false) -> WidgetBlock {
        WidgetBlock(event: CalendarEvent(
            id: title, calendarId: "cal", googleId: title, summary: title,
            startAt: instant(start), endAt: instant(end), allDay: allDay, updatedAt: instant(start)))
    }
}
