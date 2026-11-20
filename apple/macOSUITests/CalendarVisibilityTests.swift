import XCTest

final class CalendarVisibilityTests: XCTestCase {
    @MainActor
    func testHideTasksFromCalendar() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiAppearance", "light", "-demoNow", "2026-11-12T19:00:00Z"]
        let window = app.windows.firstMatch
        let toggle = app.buttons["calendar-task-visibility"]
        let task = app.staticTexts["month-task-demo-task-funds"].firstMatch
        let event = app.staticTexts["month-event-demo-event-offsite"].firstMatch
        let taskHint = app.staticTexts["month-task-demo-task-funds-jump"].firstMatch
        let eventHint = app.staticTexts["month-event-demo-event-offsite-jump"].firstMatch
        addTeardownBlock { @MainActor [weak self] in
            guard let self, (self.testRun?.failureCount ?? 0) > 0 else { return }
            self.attachScreenshot(named: "mac-calendar-task-visibility-failure")
            print("Task visibility: \(String(describing: toggle.value)); task=\(task.frame), event=\(event.frame), taskHint=\(taskHint.exists)")
        }
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        app.typeKey("m", modifierFlags: .shift)
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: [])
        XCTAssertTrue(taskHint.waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(task.waitForNonExistence(timeout: 5))
        XCTAssertTrue(event.exists)
        XCTAssertTrue(app.scrollViews["task-pane-scroll"].exists)
        app.typeKey("f", modifierFlags: [])
        XCTAssertTrue(eventHint.waitForExistence(timeout: 5))
        XCTAssertFalse(taskHint.exists)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "mac-calendar-tasks-hidden"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(task.waitForExistence(timeout: 5))
    }

    @MainActor
    func testChecklistStaysOpenAcrossTogglesAndFilters() {
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
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))

        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual((birthdays.value as? NSNumber)?.intValue, 1)
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
