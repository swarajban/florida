import Foundation
import Testing
@testable import FloridaCore

@Suite struct WindowBoundsTests {
    @Test func keepsTheDefaultSizeAndPositionWhenTheyFit() {
        let visible = CGRect(x: 0, y: 48, width: 1920, height: 1000)
        let frame = CGRect(x: 200, y: 100, width: 1240, height: 820)
        #expect(WindowBounds.clamped(frame, to: visible) == frame)
    }

    @Test func fitsAnOversizedRestoredWindowOnASmallScreen() {
        let visible = CGRect(x: 0, y: 48, width: 1024, height: 696)
        let restored = CGRect(x: -108, y: -50, width: 1240, height: 820)
        #expect(WindowBounds.clamped(restored, to: visible) == visible)
    }

    @Test(arguments: [
        CGRect(x: -300, y: 80, width: 800, height: 600),
        CGRect(x: 900, y: 80, width: 800, height: 600),
        CGRect(x: 100, y: -400, width: 800, height: 600),
        CGRect(x: 100, y: 900, width: 800, height: 600),
    ])
    func bringsEveryOffscreenEdgeBackWithoutShrinkingAFittingWindow(frame: CGRect) {
        let visible = CGRect(x: 0, y: 48, width: 1024, height: 696)
        let result = WindowBounds.clamped(frame, to: visible)
        #expect(result.size == frame.size)
        #expect(visible.contains(result))
        #expect(WindowBounds.clamped(result, to: visible) == result)
    }

    @Test func handlesMovedDisplaysWithNegativeOrigins() {
        let visible = CGRect(x: -1600, y: -400, width: 1440, height: 850)
        let restored = CGRect(x: 2000, y: 1000, width: 1240, height: 820)
        #expect(WindowBounds.clamped(restored, to: visible) == CGRect(x: -1400, y: -370, width: 1240, height: 820))
    }

    @Test func leavesTheFrameAloneWhenNoVisibleScreenExists() {
        let frame = CGRect(x: 200, y: 100, width: 1240, height: 820)
        #expect(WindowBounds.clamped(frame, to: .zero) == frame)
    }
}
