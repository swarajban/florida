import Foundation
import Testing
@testable import FloridaCore

@Suite struct BlockDragTests {
    let grid = TimeGrid(hourHeight: 60, slotMinutes: 15)
    let calendar = PacificTestCalendar.calendar

    @Test func movesBySlotsInBothDirections() {
        let drag = BlockDrag(startMinute: 9 * 60, durationMinutes: 30)
        #expect(drag.startMinute(movedBy: 90, grid: grid) == 10 * 60 + 30)
        #expect(drag.startMinute(movedBy: -120, grid: grid) == 7 * 60)
        // 20 points is nearer one slot than two; 23 is nearer two.
        #expect(drag.startMinute(movedBy: 20, grid: grid) == 9 * 60 + 15)
        #expect(drag.startMinute(movedBy: 23, grid: grid) == 9 * 60 + 30)
    }

    @Test func pointsFollowTheGridsScale() {
        let dense = TimeGrid(hourHeight: 120, slotMinutes: 30)
        let drag = BlockDrag(startMinute: 9 * 60, durationMinutes: 60)
        #expect(drag.startMinute(movedBy: 120, grid: dense) == 10 * 60)
        #expect(drag.startMinute(movedBy: 20, grid: dense) == 9 * 60)
    }

    /// A 9:05 meeting stays at 9:05 through a slip of the hand, and lands on the grid once moved.
    @Test func lessThanHalfASlotLeavesAnOffGridStartAlone() {
        let drag = BlockDrag(startMinute: 9 * 60 + 5, durationMinutes: 30)
        #expect(drag.startMinute(movedBy: 7, grid: grid) == 9 * 60 + 5)
        #expect(drag.startMinute(movedBy: -7, grid: grid) == 9 * 60 + 5)
        #expect(drag.startMinute(movedBy: 8, grid: grid) == 9 * 60 + 15)
        #expect(drag.startMinute(movedBy: -8, grid: grid) == 9 * 60)
    }

    @Test func staysInsideTheDay() {
        let drag = BlockDrag(startMinute: 9 * 60, durationMinutes: 90)
        #expect(drag.startMinute(movedBy: -5000, grid: grid) == 0)
        #expect(drag.startMinute(movedBy: 5000, grid: grid) == 22 * 60 + 30)
        // A length that is not a whole number of slots still ends by midnight, on a slot.
        let odd = BlockDrag(startMinute: 9 * 60, durationMinutes: 50)
        #expect(odd.startMinute(movedBy: 5000, grid: grid) == 23 * 60)
        let allDayLong = BlockDrag(startMinute: 0, durationMinutes: 2000)
        #expect(allDayLong.startMinute(movedBy: 300, grid: grid) == 0)
    }

    @Test func dateIsTheWallClockMinuteOfThatDay() {
        let day = PacificTestCalendar.date(2026, 11, 12, 15, 40)
        #expect(BlockDrag.date(onDay: day, minute: 10 * 60 + 30, calendar: calendar) == PacificTestCalendar.date(2026, 11, 12, 10, 30))
        #expect(BlockDrag.date(onDay: day, minute: 0, calendar: calendar) == PacificTestCalendar.date(2026, 11, 12))
        #expect(BlockDrag.date(onDay: day, minute: 5000, calendar: calendar) == PacificTestCalendar.date(2026, 11, 12, 23, 59))
    }

    /// 2026-03-08 has no 2:30 in Los Angeles; 2026-11-01 has 1:30 twice.
    @Test func dateOnADaylightSavingDay() {
        let springForward = PacificTestCalendar.date(2026, 3, 8)
        #expect(BlockDrag.date(onDay: springForward, minute: 2 * 60 + 30, calendar: calendar) == PacificTestCalendar.date(2026, 3, 8, 3, 0))
        // 9:00 is eight hours after midnight on the short day, not nine.
        let nine = BlockDrag.date(onDay: springForward, minute: 9 * 60, calendar: calendar)
        #expect(nine.timeIntervalSince(springForward) == 8 * 3600)

        let fallBack = PacificTestCalendar.date(2026, 11, 1)
        let first = BlockDrag.date(onDay: fallBack, minute: 90, calendar: calendar)
        #expect(first.timeIntervalSince(fallBack) == 90 * 60)
    }
}
