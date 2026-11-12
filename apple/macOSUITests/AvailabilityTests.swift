import XCTest

final class AvailabilityTests: XCTestCase {
    @MainActor
    func testShareAvailabilityWithoutChangingCalendar() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
            app.typeKey("w", modifierFlags: [])
            app.typeKey("l", modifierFlags: .shift)

            openAvailability(app)
            let preview = app.staticTexts["availability-preview"]
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            let initial = preview.value as? String ?? preview.label
            XCTAssertFalse(initial.isEmpty)
            XCTAssertTrue(app.buttons["availability-copy"].isEnabled)
            XCTAssertTrue(app.staticTexts["availability-sync-warning"].exists)
            app.typeKey(.downArrow, modifierFlags: [])
            let moved = preview.value as? String ?? preview.label
            XCTAssertNotEqual(moved, initial)
            app.typeKey(.downArrow, modifierFlags: .shift)
            XCTAssertNotEqual(preview.value as? String ?? preview.label, moved)
            app.typeKey(.tab, modifierFlags: [])
            app.typeKey(.space, modifierFlags: [])
            let toggled = preview.value as? String ?? preview.label
            app.typeKey(.space, modifierFlags: [])
            XCTAssertNotEqual(preview.value as? String ?? preview.label, toggled)
            app.typeKey("3", modifierFlags: [])
            XCTAssertEqual(app.popUpButtons["availability-duration"].value as? String, "45m")

            app.typeKey("z", modifierFlags: [])
            let search = app.textFields["availability-zone-search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.typeText("Asia/Tokyo")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(search.waitForNonExistence(timeout: 5))
            XCTAssertTrue((preview.value as? String ?? preview.label).contains("Asia/Tokyo"))

            let grid = app.otherElements["calendar-time-grid"]
            XCTAssertTrue(grid.exists)
            let x = (56 + (grid.frame.width - 56) * 4.5 / 7) / grid.frame.width
            let start = grid.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 540.0 / 1440))
            let end = grid.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 600.0 / 1440))
            let beforeDrag = preview.value as? String ?? preview.label
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            XCTAssertNotEqual(preview.value as? String ?? preview.label, beforeDrag)
            capture(app.windows.firstMatch, "availability-\(appearance)")
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            XCTAssertEqual(preview.value as? String ?? preview.label, beforeDrag)

            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Availability copied"].exists)
            app.typeKey("c", modifierFlags: [])
            let paste = app.textFields.firstMatch
            XCTAssertTrue(paste.waitForExistence(timeout: 5))
            paste.typeKey("v", modifierFlags: .command)
            XCTAssertTrue((paste.value as? String)?.contains("Asia/Tokyo") == true)
            XCTAssertTrue((paste.value as? String)?.contains("Not synced yet") == true)
            app.typeKey(.escape, modifierFlags: [])

            openAvailability(app)
            app.typeKey(.space, modifierFlags: [])
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
            app.typeKey("t", modifierFlags: [])
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].exists)
            app.terminate()
        }
    }

    @MainActor
    private func openAvailability(_ app: XCUIApplication) {
        app.typeKey("k", modifierFlags: .command)
        let input = app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("Share availability")
        app.typeKey(.return, modifierFlags: [])
    }

    @MainActor
    private func capture(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
