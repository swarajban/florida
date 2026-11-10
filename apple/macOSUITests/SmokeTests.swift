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

    /// Projects, the brief and the task editor, new and on an open task, each opened by its keys.
    @MainActor
    func testPlanScreensInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            defer { app.terminate() }
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["open-projects"].exists)
            XCTAssertTrue(app.buttons["open-brief"].exists)

            // The hour three projects share is after lunch: day view, scrolled to the afternoon.
            app.typeKey("d", modifierFlags: [])
            XCTAssertEqual((app.radioButtons["Day"].value as? NSNumber)?.intValue, 1)
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.7)).scroll(byDeltaX: 0, deltaY: -260)
            capture(window, "lanes-\(appearance)")

            app.typeKey("g", modifierFlags: [])
            app.typeKey("p", modifierFlags: [])
            // A project with no tasks: only the Projects sheet can show it.
            XCTAssertTrue(app.staticTexts["Home network rebuild"].waitForExistence(timeout: 5))
            capture(window, "projects-\(appearance)")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.staticTexts["Home network rebuild"].waitForNonExistence(timeout: 5))

            app.typeKey("g", modifierFlags: [])
            app.typeKey("b", modifierFlags: [])
            let headline = app.staticTexts["Keys first, then a three-project hour after lunch"]
            XCTAssertTrue(headline.waitForExistence(timeout: 5))
            capture(window, "brief-\(appearance)")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(headline.waitForNonExistence(timeout: 5))

            app.typeKey("n", modifierFlags: .shift)
            XCTAssertTrue(app.popUpButtons["task-project"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.popUpButtons["task-attention"].exists)
            capture(window, "task-editor-\(appearance)")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.popUpButtons["task-project"].waitForNonExistence(timeout: 5))

            // An open task: Mark done on top, then both dates. This one was due yesterday, so
            // a start of today moves its due date to tomorrow.
            app.staticTexts["Renew VPN certificate"].firstMatch.doubleClick()
            XCTAssertTrue(app.buttons["Mark done"].waitForExistence(timeout: 5))
            app.checkBoxes["Start"].click()
            capture(window, "task-editor-open-\(appearance)")
            app.typeKey(.escape, modifierFlags: [])
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
