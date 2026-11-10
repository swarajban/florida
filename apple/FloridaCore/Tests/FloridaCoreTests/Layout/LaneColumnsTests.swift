import Foundation
import Testing
@testable import FloridaCore

@Suite struct LaneColumnsTests {
    let calendar = PacificTestCalendar.calendar
    let day = PacificTestCalendar.date(2026, 11, 4)

    func item(_ id: String, _ start: (Int, Int), _ end: (Int, Int)) -> LayoutItem<String> {
        LayoutItem(
            id: id, start: PacificTestCalendar.date(2026, 11, 4, start.0, start.1),
            end: PacificTestCalendar.date(2026, 11, 4, end.0, end.1))
    }

    func columns(_ items: [LayoutItem<String>], lanes: [String: Int]) -> [String: [Int]] {
        let frames = LaneColumns.ordered(DayLayout.layout(items, day: day, calendar: calendar), lanes: lanes)
        return Dictionary(uniqueKeysWithValues: frames.map { ($0.id, [$0.column, $0.columnCount]) })
    }

    @Test func aLongerHigherLaneStillSitsRightOfTheLowerOne() {
        // `DayLayout` alone puts the longer block first, which would swap the lanes.
        let items = [item("lane0", (13, 30), (14, 30)), item("lane1", (13, 30), (15, 0))]
        let plain = DayLayout.layout(items, day: day, calendar: calendar)
        #expect(plain.first { $0.id == "lane1" }?.column == 0)

        #expect(columns(items, lanes: ["lane0": 0, "lane1": 1]) == ["lane0": [0, 2], "lane1": [1, 2]])
    }

    @Test func aLaneThatStartsLaterKeepsItsSideOfAnEarlierHigherLane() {
        let items = [item("lane2", (13, 0), (15, 0)), item("lane0", (13, 30), (14, 30)), item("lane1", (14, 0), (15, 0))]
        #expect(
            columns(items, lanes: ["lane0": 0, "lane1": 1, "lane2": 2])
                == ["lane0": [0, 3], "lane1": [1, 3], "lane2": [2, 3]])
    }

    @Test func blocksWithoutALaneStayLeftOfTheLanes() {
        // An event added since the scheduler ran overlaps two lanes.
        let items = [item("lane0", (13, 0), (14, 0)), item("lane1", (13, 0), (14, 0)), item("event", (13, 30), (14, 30))]
        #expect(
            columns(items, lanes: ["lane0": 0, "lane1": 1])
                == ["event": [0, 3], "lane0": [1, 3], "lane1": [2, 3]])
    }

    @Test func aClusterWithOneLaneIsLeftAsDayLayoutPackedIt() {
        let items = [item("event", (9, 0), (10, 0)), item("lane0", (9, 0), (9, 30)), item("later", (11, 0), (12, 0))]
        let plain = DayLayout.layout(items, day: day, calendar: calendar)
        #expect(LaneColumns.ordered(plain, lanes: ["lane0": 0, "later": 1]) == plain)
    }
}
