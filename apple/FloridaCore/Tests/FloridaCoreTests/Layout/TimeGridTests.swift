import Foundation
import Testing
@testable import FloridaCore

@Suite struct TimeGridTests {
    let grid = TimeGrid(hourHeight: 60, slotMinutes: 15)

    @Test func defaultsAreSixtyPointsAndQuarterHours() {
        let defaults = TimeGrid()
        #expect(defaults.hourHeight == 60)
        #expect(defaults.slotMinutes == 15)
    }

    @Test func convertsMinutesToPoints() {
        #expect(grid.y(forMinute: 0) == 0)
        #expect(grid.y(forMinute: 60) == 60)
        #expect(grid.y(forMinute: 90) == 90)
        #expect(grid.y(forMinute: 1440) == grid.dayHeight)
        #expect(grid.dayHeight == 1440)

        let dense = TimeGrid(hourHeight: 48, slotMinutes: 30)
        #expect(dense.y(forMinute: 60) == 48)
        #expect(dense.y(forMinute: 30) == 24)
        #expect(dense.y(forMinute: 15) == 12)
        #expect(dense.dayHeight == 24 * 48)
    }

    @Test func exactMinuteFloorsAndClamps() {
        #expect(grid.minute(forY: 0) == 0)
        #expect(grid.minute(forY: 30) == 30)
        #expect(grid.minute(forY: 15.9) == 15)
        #expect(grid.minute(forY: 7.2) == 7)
        #expect(grid.minute(forY: -5) == 0)
        #expect(grid.minute(forY: 1440) == 1440)
        #expect(grid.minute(forY: 2000) == 1440)

        let dense = TimeGrid(hourHeight: 48, slotMinutes: 15)
        #expect(dense.minute(forY: 48) == 60)
        #expect(dense.minute(forY: 24) == 30)
    }

    @Test func snapsToNearestSlotOnEitherSideOfBoundary() {
        // Just below and just above the 15-minute line both land on 15.
        #expect(grid.snappedMinute(forY: 14) == 15)
        #expect(grid.snappedMinute(forY: 16) == 15)
        #expect(grid.snappedMinute(forY: 15) == 15)
        // Either side of the midpoint between slots goes to the nearer slot.
        #expect(grid.snappedMinute(forY: 7) == 0)
        #expect(grid.snappedMinute(forY: 8) == 15)
        #expect(grid.snappedMinute(forY: 22) == 15)
        #expect(grid.snappedMinute(forY: 23) == 30)
        #expect(grid.snappedMinute(forY: 59) == 60)
        #expect(grid.snappedMinute(forY: 100) == 105)

        let dense = TimeGrid(hourHeight: 48, slotMinutes: 30)
        #expect(dense.snappedMinute(forY: 11) == 0)
        #expect(dense.snappedMinute(forY: 13) == 30)
        #expect(dense.snappedMinute(forY: 48) == 60)
    }

    @Test func snappingClampsToDay() {
        #expect(grid.snappedMinute(forY: -5) == 0)
        #expect(grid.snappedMinute(forY: -100) == 0)
        #expect(grid.snappedMinute(forY: 1439) == 1440)
        #expect(grid.snappedMinute(forY: 1440) == 1440)
        #expect(grid.snappedMinute(forY: 2000) == 1440)
    }

    @Test func eventDragSnapsBothEndsAndKeepsAtLeastOneSlot() {
        #expect(grid.eventMinutes(from: 544, to: 582) == 540...585)
        #expect(grid.eventMinutes(from: 582, to: 544) == 540...585)
        #expect(grid.eventMinutes(from: 540, to: 545) == 540...555)
        #expect(grid.eventMinutes(from: 540, to: 535) == 525...540)
        #expect(grid.eventMinutes(from: 1, to: -20) == 0...15)
        #expect(grid.eventMinutes(from: 1439, to: 1500) == 1425...1440)
        #expect(grid.eventStartMinute(forY: 1439) == 1425)
    }

    @Test func eventCreationDistinguishesClicksAndReservesAColumnGutter() {
        #expect(!TimeGrid.eventDragHasStarted(dx: 1, dy: 5))
        #expect(TimeGrid.eventDragHasStarted(dx: 0, dy: -6))
        #expect(TimeGrid.eventColumnContentWidth(120) == 104)
        #expect(TimeGrid.eventColumnContentWidth(36) == 24)
    }

    @Test func eventDragCanEndAtNextMidnightEvenOnADSTDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let late = grid.eventDates(on: day, minutes: 1425...1440, calendar: calendar)
        #expect(calendar.component(.hour, from: late.upperBound) == 0)
        #expect(calendar.component(.day, from: late.upperBound) == 9)
        #expect(late.upperBound.timeIntervalSince(late.lowerBound) == 15 * 60)
        let skipped = grid.eventDates(on: day, minutes: 120...135, calendar: calendar)
        #expect(calendar.component(.hour, from: skipped.lowerBound) == 3)
        #expect(skipped.upperBound.timeIntervalSince(skipped.lowerBound) == 15 * 60)
    }

    @Test func hourLabelsAreTwelveHourEnglish() {
        let labels = TimeGrid.hourLabels()
        #expect(labels.count == 24)
        #expect(labels[0].minute == 0 && labels[0].label == "12 AM")
        #expect(labels[1].minute == 60 && labels[1].label == "1 AM")
        #expect(labels[11].minute == 660 && labels[11].label == "11 AM")
        #expect(labels[12].minute == 720 && labels[12].label == "12 PM")
        #expect(labels[13].minute == 780 && labels[13].label == "1 PM")
        #expect(labels[23].minute == 1380 && labels[23].label == "11 PM")
        #expect(labels.map(\.minute) == (0..<24).map { $0 * 60 })
    }
}
