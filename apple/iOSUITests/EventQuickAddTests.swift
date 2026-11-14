import XCTest

final class EventQuickAddTests: XCTestCase {
    @MainActor
    func testPreviewCorrectionAndLocalSave() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openComposer(app)
            let input = app.textFields["event-quick-add-input"]
            input.typeText("Lunch today 12-1 at Blue Bottle #demo-cal-work")
            XCTAssertTrue(app.buttons["event-quick-add-title"].label.contains("Lunch"))
            XCTAssertTrue(app.buttons["event-quick-add-location"].label.contains("Blue Bottle"))
            XCTAssertTrue(element("event-quick-add-destination", in: app).label.contains("demo@sempre-health.com"))
            capture(app, "event-composer-preview-\(appearance)")

            app.buttons["event-quick-add-title"].tap()
            let title = app.textFields["event-quick-add-edit-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "Lunch with Dana")
            app.buttons["event-quick-add-correction-done"].tap()
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))
            app.buttons["event-quick-add-location"].tap()
            let location = app.textFields["event-quick-add-edit-location"]
            XCTAssertTrue(location.waitForExistence(timeout: 5))
            location.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 11) + "Cafe Luna")
            app.buttons["event-quick-add-correction-done"].tap()
            XCTAssertTrue(location.waitForNonExistence(timeout: 5))

            app.buttons["event-quick-add-calendar"].tap()
            let personal = app.buttons["event-quick-add-calendar-demo-cal-personal"]
            XCTAssertTrue(personal.waitForExistence(timeout: 5))
            personal.tap()
            XCTAssertTrue(personal.waitForNonExistence(timeout: 5))
            XCTAssertTrue(element("event-quick-add-destination", in: app).label.contains("demo@personal.example"))
            XCTAssertTrue(app.buttons["event-quick-add-title"].label.contains("Lunch with Dana"))
            capture(app, "event-composer-corrected-\(appearance)")
            input.tap()
            input.typeText("\n")
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))

            let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Lunch with Dana")).firstMatch
            for _ in 0..<5 where !saved.isHittable { app.swipeUp() }
            XCTAssertTrue(saved.waitForExistence(timeout: 5))
            saved.tap()
            XCTAssertTrue(app.navigationBars["Event"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Cafe Luna"].exists)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "demo@personal.example")).firstMatch.exists)
            capture(app, "event-composer-saved-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testDetailsPreserveParsedEventAndRecurrence() {
        continueAfterFailure = false
        let app = launch()
        openComposer(app)
        app.textFields["event-quick-add-input"].typeText("Dentist every tuesday 3pm 45m at Blue Bottle #demo-cal-work")
        XCTAssertTrue(app.buttons["event-quick-add-recurrence"].label.contains("Every 1 week"))
        app.buttons["event-quick-add-details"].tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Dentist")
        XCTAssertEqual(app.textFields["Location"].value as? String, "Blue Bottle")
        XCTAssertTrue(app.buttons["event-repeat"].label.contains("Weekly"))
        XCTAssertTrue(app.buttons["event-calendar"].label.contains("demo@sempre-health.com"))
        XCTAssertTrue(app.staticTexts["event-account"].label.contains("demo@sempre-health.com"))
        capture(app, "event-composer-details")
        app.terminate()
    }

    @MainActor
    func testUnresolvedCalendarBlocksSaveAndAllDayPreview() {
        continueAfterFailure = false
        let app = launch(largeText: true)
        openComposer(app)
        app.textFields["event-quick-add-input"].typeText("Day off today all day #missing-calendar")
        let keyboardIntroduction = app.buttons["Continue"]
        if keyboardIntroduction.exists { keyboardIntroduction.tap() }
        XCTAssertFalse(keyboardIntroduction.exists)
        app.buttons["event-quick-add-hide-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["event-quick-add-save"].isEnabled)
        XCTAssertTrue(element("event-quick-add-error", in: app).exists)
        XCTAssertTrue(app.buttons["event-quick-add-calendar"].exists)
        app.buttons["event-quick-add-destination"].tap()
        let personal = app.buttons["event-quick-add-calendar-demo-cal-personal"]
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        personal.tap()
        XCTAssertTrue(personal.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["event-quick-add-time"].label.contains("All day"))
        XCTAssertTrue(app.buttons["event-quick-add-save"].isEnabled)
        capture(app, "event-composer-all-day-large-text")
        app.buttons["event-quick-add-save"].tap()
        XCTAssertTrue(app.textFields["event-quick-add-input"].waitForNonExistence(timeout: 5))
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND identifier != %@", "Day off", "agenda-day-kind")).firstMatch
        for _ in 0..<8 where !saved.exists { app.collectionViews.firstMatch.swipeDown() }
        let list = app.collectionViews.firstMatch
        for _ in 0..<12 where !saved.exists {
            let frame = list.frame
            let bottom = min(frame.maxY, app.tabBars.firstMatch.frame.minY)
            let from = list.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.width * 0.5, dy: (bottom - frame.minY) * 0.9))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertTrue((saved.value as? String)?.contains("All day") == true)
        saved.tap()
        XCTAssertTrue(app.navigationBars["Event"].waitForExistence(timeout: 5))
        capture(app, "event-composer-all-day-saved")
        app.terminate()
    }

    @MainActor
    private func openComposer(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["agenda-add"].waitForExistence(timeout: 15))
        app.buttons["agenda-add"].tap()
        app.buttons["New Event"].tap()
        XCTAssertTrue(app.textFields["event-quick-add-input"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launch(appearance: String = "light", largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-demoData", "YES", "-uiTab", "agenda", "-uiAppearance", appearance,
            "-uiAgendaMode", "list", "-UIPreferredContentSizeCategoryName",
            largeText ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
