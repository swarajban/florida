import Foundation
import Testing
@testable import FloridaCore

@Suite struct EventDayBlockingTests {
    let legacy = """
        {"id":"e","calendarId":"cal","googleId":"g-e","status":"confirmed","summary":"Holiday",
         "startAt":"2026-11-09T00:00:00Z","endAt":"2026-11-10T00:00:00Z","allDay":true,
         "updatedAt":"2026-11-08T00:00:00Z"}
        """

    @Test func oldEventsAndQueuedWritesDecodeAsAutomatic() throws {
        let event = try JSONCoding.decoder.decode(CalendarEvent.self, from: Data(legacy.utf8))
        #expect(event.blocksDay == nil)
        let write = try JSONCoding.decoder.decode(EventWrite.self, from: Data(legacy.utf8))
        #expect(write.blocksDay == nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(write)) as? [String: Any])
        #expect(object["blocksDay"] is NSNull)
    }

    @Test(arguments: [nil, true, false] as [Bool?])
    func explicitOverridesAndAutomaticRoundTrip(blocksDay: Bool?) throws {
        var event = try JSONCoding.decoder.decode(CalendarEvent.self, from: Data(legacy.utf8))
        event.blocksDay = blocksDay
        let data = try JSONCoding.encoder.encode(event)
        #expect(try JSONCoding.decoder.decode(CalendarEvent.self, from: data) == event)
        let write = try #require(EventWrite(event))
        #expect(write.blocksDay == blocksDay)
        let body = try JSONCoding.encoder.encode(write)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        if let blocksDay {
            #expect(object["blocksDay"] as? Bool == blocksDay)
        } else {
            #expect(object["blocksDay"] is NSNull)
        }
        #expect(try JSONCoding.decoder.decode(EventWrite.self, from: body) == write)
    }
}
