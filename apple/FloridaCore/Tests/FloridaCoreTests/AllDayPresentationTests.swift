import Foundation
import Testing
@testable import FloridaCore

@Suite struct AllDayPresentationTests {
    func event(_ id: String, title: String = "Marcus Chen - Out of Office") -> CalendarEvent {
        CalendarEvent(id: id, calendarId: "gusto", googleId: id, summary: title, allDay: true,
                      updatedAt: .distantPast, autoBlocksDay: false, blockingReason: "Someone else’s time off")
    }

    @Test(arguments: [0, 1, 2, 5])
    func groupsCoworkers(count: Int) {
        let names = ["Marcus Chen", "Priya Shah", "Alex Li", "Sam Jones", "Jo Lane"]
        let events = (0..<count).map { event("\($0)", title: "\(names[$0]) - Out of Office") }
        let items = AllDayPresentation.items(for: events)
        #expect(items.count == (count == 0 ? 0 : 1))
        if count > 0 {
            #expect(items[0].events == events)
            #expect(items[0].isGroup == (count > 1))
            #expect(items[0].title == (count == 1 ? "OOO: Marcus" : count == 2 ? "OOO: Marcus, Priya" : "OOO: Marcus, Priya +3"))
        }
    }

    @Test func preservesOtherEventsAndBlockingOverrides() {
        var others = ["Trip to LA", "Infra offsite", "Company holiday", "My PTO"].enumerated().map {
            event("other-\($0.offset)", title: $0.element)
        }
        others[3].autoBlocksDay = true
        others[3].blockingReason = "Your time off"
        var manual = event("manual")
        manual.blocksDay = true
        let events = [event("a")] + others + [manual, event("b")]
        let items = AllDayPresentation.items(for: events, calendarName: { _ in "Gusto" })
        #expect(items.count == 6)
        #expect(items[0].events.map(\.id) == ["a", "b"])
        #expect(items.dropFirst().flatMap(\.events) == others + [manual])
    }

    @Test func requiresTimeOffAndGustoEvidence() {
        var e = event("e")
        e.blockingReason = nil
        #expect(!AllDayPresentation.isCoworkerOOO(e, calendarName: "Personal"))
        #expect(AllDayPresentation.isCoworkerOOO(e, calendarName: "Gusto time off"))
        e.autoBlocksDay = true
        #expect(!AllDayPresentation.isCoworkerOOO(e, calendarName: "Gusto"))
        e.blocksDay = false
        e.blockingReason = "Your time off"
        #expect(!AllDayPresentation.isCoworkerOOO(e, calendarName: "Gusto"))
        e.blockingReason = "Someone else’s time off"
        e.allDay = false
        #expect(!AllDayPresentation.isCoworkerOOO(e, calendarName: "Gusto"))
        e.allDay = true
        e.status = "cancelled"
        #expect(!AllDayPresentation.isCoworkerOOO(e, calendarName: "Gusto"))
    }

    @Test(arguments: [
        ("Marcus Chen - Out of Office", "Marcus"), ("Marcus out of office", "Marcus"),
        ("Pending Priya Shah is on PTO", "Priya"), ("OOO: Élodie Martin", "Élodie"),
        ("  Jo-Anne Lee — vacation  ", "Jo-Anne"), ("Out of Office", "Someone"),
        ("My PTO", "Someone"), ("", "Someone"), ("李 明 - time off", "李"),
    ])
    func extractsNames(title: String, name: String) {
        #expect(AllDayPresentation.shortName(from: title) == name)
    }
}
