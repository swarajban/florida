import XCTest

final class CalendarVisibilityTests: XCTestCase {
    @MainActor
    func testChecklistStaysOpenAcrossTogglesAndFilters() {
        let app = launchDemo()
        let button = app.buttons["calendar-visibility-button"]
        let search = app.textFields["calendar-visibility-search"]
        let ooo = app.checkBoxes["calendar-visibility-row-demo-cal-ooo"]
        let birthdays = app.checkBoxes["calendar-visibility-row-demo-cal-birthdays"]

        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        ooo.click()
        birthdays.click()
        let unchecked = NSPredicate(format: "value == 0")
        let checked = NSPredicate(format: "value == 1")
        let result = XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: unchecked, object: ooo),
            XCTNSPredicateExpectation(predicate: checked, object: birthdays),
        ], timeout: 5)
        XCTAssertEqual(result, .completed,
                       "OOO: \(ooo.value ?? "missing") at \(ooo.frame); Birthdays: \(birthdays.value ?? "missing") at \(birthdays.frame)")
        attachScreenshot(named: "calendars-checklist")

        search.click()
        search.typeText("birthday")
        XCTAssertTrue(ooo.waitForNonExistence(timeout: 5))
        XCTAssertTrue(birthdays.isHittable)
    }

    @MainActor
    func testCalendarMenuShortcutAndPaletteOpenTheSameChecklist() {
        let app = launchDemo()
        let search = app.textFields["calendar-visibility-search"]
        let calendar = app.menuBars.menuBarItems["Calendar"]
        XCTAssertTrue(app.buttons["calendar-visibility-button"].waitForExistence(timeout: 10))

        calendar.click()
        calendar.menus.menuItems["Toggle Calendars"].click()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))

        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))

        app.typeKey("k", modifierFlags: .command)
        app.textFields["palette-input"].typeText("Toggle calendars")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchDemo() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiAppearance", "light"]
        app.launch()
        addTeardownBlock {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "calendars-teardown"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            app.terminate()
        }
        return app
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
