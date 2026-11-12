import Foundation
import Testing
@testable import FloridaKit

struct EventQuickAddStoreTests {
    @Test(arguments: ["GMT", "America/Los_Angeles", "Asia/Tokyo"])
    func allDayCaptureAppearsLocallyAndQueuesDateBasedWrite(_ zone: String) throws {
        let db = try AppDatabase.inMemory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let now = Fixtures.instant("2026-11-12T18:00:00Z")
        let account = Fixtures.account(id: "personal")
        let destination = Fixtures.calendar(id: "personal", accountId: account.id)
        try db.apply(SyncResponse(cursor: "c", accounts: [account], calendars: [destination]))
        let template = CalendarEvent(
            id: "capture", calendarId: destination.id, googleId: "", startAt: now,
            endAt: now.addingTimeInterval(1800), updatedAt: now)
        var session = EventQuickAddSession(event: template, now: now, calendar: calendar)
        session.updateText("Day off today all day #missing-calendar")
        #expect(session.event(in: [destination], accounts: [account]) == nil)
        session.chooseCalendar(destination.id)
        let event = try #require(session.event(in: [destination], accounts: [account]))
        try db.saveEvent(event, now: now)
        let agenda = try db.agenda(for: now, calendar: calendar)
        let saved = try #require(agenda.events.first { $0.id == event.id })
        #expect(saved.summary == "Day off")
        #expect(saved.allDay)
        #expect(saved.startAt == AllDayDate.storedInstant(forLocalDay: now, calendar: calendar))
        let pending = try #require(try db.pendingWrites().first)
        let write = try JSONCoding.decoder.decode(EventWrite.self, from: try #require(pending.body))
        #expect(write.summary == "Day off")
        #expect(write.allDay)
        #expect(write.startAt == saved.startAt)
        #expect(write.endAt == saved.endAt)
        #expect(write.recurrence == nil)
    }
}
