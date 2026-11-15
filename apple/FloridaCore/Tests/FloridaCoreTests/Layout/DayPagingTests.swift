import Testing
@testable import FloridaCore

struct DayPagingTests {
    @Test func fastFlickMovesAtMostOneDay() {
        #expect(DayPaging.targetOffset(proposed: 5000, original: 2800, pageWidth: 400, pageCount: 15) == 3200)
        #expect(DayPaging.targetOffset(proposed: 0, original: 2800, pageWidth: 400, pageCount: 15) == 2400)
    }

    @Test func targetsStayOnRunway() {
        #expect(DayPaging.targetOffset(proposed: -500, original: 0, pageWidth: 400, pageCount: 15) == 0)
        #expect(DayPaging.targetOffset(proposed: 7000, original: 5600, pageWidth: 400, pageCount: 15) == 5600)
    }

    @Test func slowDragRoundsToNearestDay() {
        #expect(DayPaging.targetOffset(proposed: 2940, original: 2800, pageWidth: 400, pageCount: 15) == 2800)
        #expect(DayPaging.targetOffset(proposed: 3060, original: 2800, pageWidth: 400, pageCount: 15) == 3200)
        #expect(DayPaging.targetOffset(proposed: 2540, original: 2800, pageWidth: 400, pageCount: 15) == 2400)
    }

    @Test func settlementHandlesBounceAndFractionalWidths() {
        #expect(DayPaging.settledIndex(offset: -100, pageWidth: 390.5, pageCount: 15) == 0)
        #expect(DayPaging.settledIndex(offset: 20_000, pageWidth: 390.5, pageCount: 15) == 14)
        #expect(DayPaging.settledIndex(offset: 7 * 390.5 + 1, pageWidth: 390.5, pageCount: 15) == 7)
    }

    @Test func emptyOrUnlaidOutPagerHasNoOffset() {
        #expect(DayPaging.targetOffset(proposed: 500, original: 0, pageWidth: 0, pageCount: 15) == 0)
        #expect(DayPaging.settledIndex(offset: 500, pageWidth: 400, pageCount: 0) == 0)
    }
}
