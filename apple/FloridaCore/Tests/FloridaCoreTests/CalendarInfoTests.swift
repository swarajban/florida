import Foundation
import Testing
@testable import FloridaCore

@Suite struct CalendarInfoTests {
    @Test(arguments: [false, true])
    func olderPayloadsDefaultToBlockingRegardlessOfVisibility(selected: Bool) throws {
        let json = """
            {"id":"cal","accountId":"account","googleId":"g-cal","summary":"Work",
             "accessRole":"reader","selected":\(selected),"updatedAt":"2026-11-09T00:00:00Z"}
            """
        let calendar = try JSONCoding.decoder.decode(CalendarInfo.self, from: Data(json.utf8))
        #expect(calendar.selected == selected)
        #expect(calendar.blocksScheduling)
        #expect(calendar.color == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func visibilityAndBlockingRoundTripIndependently(selected: Bool, blocksScheduling: Bool) throws {
        let calendar = CalendarInfo(
            id: "cal", accountId: "account", googleId: "g-cal", summary: "Work", color: "#123456",
            accessRole: "owner", selected: selected, blocksScheduling: blocksScheduling,
            updatedAt: Date(timeIntervalSince1970: 1_794_182_400))
        let data = try JSONCoding.encoder.encode(calendar)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["selected"] as? Bool == selected)
        #expect(object["blocksScheduling"] as? Bool == blocksScheduling)
        #expect(try JSONCoding.decoder.decode(CalendarInfo.self, from: data) == calendar)
    }

    @Test func initializerDefaultsToBlockingForHiddenCalendars() {
        let calendar = CalendarInfo(
            id: "cal", accountId: "account", googleId: "g-cal", summary: "Hidden",
            accessRole: "owner", selected: false, updatedAt: .distantPast)
        #expect(calendar.blocksScheduling)
    }
}
