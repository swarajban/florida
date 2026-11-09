import XCTest

/// Exercise the real window and keyboard route, not a second implementation of the screens.
/// Kept screenshots are exported from the result bundle by CI for light/dark visual review.
final class SmokeTests: XCTestCase {
    @MainActor
    func testCalendarAndQuickAddInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            defer { app.terminate() }
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 10))
            app.buttons["Today"].hover()
            capture(window, "calendar-\(appearance)")

            app.typeKey("k", modifierFlags: .command)
            let input = app.textFields.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.hover()
            input.typeText("Next day")
            XCTAssertEqual(input.value as? String, ">Next day")
            XCTAssertTrue(app.staticTexts["Next day"].exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))

            app.typeKey("c", modifierFlags: [])
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("Write launch notes 30m")
            XCTAssertTrue(app.staticTexts["Write launch notes"].exists)
            capture(window, "quick-add-\(appearance)")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Write launch notes"].waitForExistence(timeout: 5))

            // Capture month mode after the text field resigns focus.
            app.typeKey("m", modifierFlags: .shift)
            XCTAssertEqual((app.radioButtons["Month"].value as? NSNumber)?.intValue, 1)
            capture(window, "month-\(appearance)")
        }
    }

    @MainActor
    private func capture(_ window: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
