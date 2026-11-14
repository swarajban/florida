import XCTest

final class TaskDateRegressionTests: XCTestCase {
    @MainActor
    func testPastDueIsOverdueAndAFutureMissIsLate() {
        continueAfterFailure = false
        for flag in ["-uiTaskDatePast", "-uiTaskDateLate"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiTaskDateDemo", "YES", flag, "YES",
                                   "-uiTab", "tasks", "-demoNow", "2026-11-13T17:00:00Z"]
            app.launch()
            defer { app.terminate() }
            let row = app.buttons["tasks-row-date-updated"]
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            XCTAssertEqual(row.label.contains("Overdue"), flag == "-uiTaskDatePast", row.label)
            XCTAssertEqual(row.label.contains("Late"), flag == "-uiTaskDateLate", row.label)
        }
    }

    @MainActor
    func testEditedDueDateRefreshesAfterSaveAndReopen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiTaskDateDemo", "YES", "-uiTab", "tasks",
                               "-demoNow", "2026-11-13T17:00:00Z"]
        app.launch()
        defer { app.terminate() }
        let menu = app.buttons["tasks-view-options"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["Due date"].tap()
        let row = app.buttons["tasks-row-date-updated"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        chooseDay("November 11", in: app)
        app.navigationBars["Edit Task"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Overdue"), row.label)
        XCTAssertTrue(row.label.contains("Nov 11"), row.label)
        row.tap()
        chooseDay("November 17", in: app)
        app.navigationBars["Edit Task"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.label.contains("Overdue"), row.label)
        XCTAssertTrue(row.label.contains("By Tuesday"), row.label)
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit Task"].waitForExistence(timeout: 5))
        let savedDue = app.descendants(matching: .any).matching(identifier: "task-due-date").firstMatch
        XCTAssertTrue(savedDue.exists)
        let value = (savedDue.value as? String) ?? (savedDue.buttons.firstMatch.value as? String) ?? ""
        XCTAssertNotNil(value.range(of: "(?:Nov(?:ember)?\\s+17,?\\s+2026|11/17/(?:2026|26)|2026-11-17)",
                                    options: .regularExpression), savedDue.debugDescription)
        XCTAssertEqual(value, "Nov 17, 2026", savedDue.debugDescription)
        app.buttons["task-editor-cancel"].tap()
        XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.label.contains("Overdue"), row.label)
        XCTAssertTrue(row.label.contains("By Tuesday"), row.label)
    }

    @MainActor
    private func chooseDay(_ day: String, in app: XCUIApplication) {
        let options = app.buttons["task-due-options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
        if app.buttons["Remove the time"].exists {
            app.buttons["Remove the time"].tap()
        } else {
            app.navigationBars["Edit Task"].tap()
        }
        let date = app.descendants(matching: .any).matching(identifier: "task-due-date").firstMatch
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        date.tap()
        let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", day)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        app.navigationBars["Edit Task"].tap()
    }

    @MainActor
    func testFutureDueAndPlacementUseTheSectionTimeZoneInBothAppearances() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiTaskDateDemo", "YES", "-uiAppearance", appearance,
                                   "-uiTab", "tasks", "-demoNow", "2026-11-13T17:00:00Z"]
            app.launch()
            defer { app.terminate() }
            let menu = app.buttons["tasks-view-options"]
            XCTAssertTrue(menu.waitForExistence(timeout: 15))
            menu.tap()
            app.buttons["Due date"].tap()
            let row = app.buttons["tasks-row-date-updated"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "tasks-section-next-week")
                .firstMatch.exists)
            XCTAssertFalse(row.label.contains("Overdue"))
            XCTAssertFalse(row.label.contains("Late"))
            XCTAssertTrue(row.label.contains("By Tuesday"), row.label)
            XCTAssertTrue(row.label.contains("12:00"), row.label)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "task-date-iphone-\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
