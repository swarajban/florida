import XCTest

final class TaskTriageTests: XCTestCase {
    @MainActor
    func testSomedayDateIntentSourceAndUndoInBothAppearances() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-demoData", "YES", "-uiAppearance", appearance, "-uiTaskGroupingDemo", "YES",
                "-uiRecordSourceOpens", "YES", "-demoNow", "2026-11-18T12:00:00Z",
            ]
            app.launch()
            defer { app.terminate() }
            let grouping = app.descendants(matching: .any).matching(identifier: "task-grouping-menu").firstMatch
            XCTAssertTrue(grouping.waitForExistence(timeout: 15))
            grouping.click()
            app.menuItems["Due date"].click()
            app.typeKey("g", modifierFlags: [])
            app.typeKey("t", modifierFlags: [])
            app.typeKey("g", modifierFlags: [])
            app.typeKey("g", modifierFlags: [])
            let row = app.descendants(matching: .any).matching(identifier: "task-row-group-categorized-inbox").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(row.label.hasSuffix(", Inbox"))
            let chip = row.descendants(matching: .any).matching(identifier: "task-category-chip-demo-eng").firstMatch
            XCTAssertEqual(chip.value as? String, "Category: Work Engineering")
            XCTAssertTrue(app.buttons["task-triage-date-group-categorized-inbox"].exists)
            app.typeKey("i", modifierFlags: [])
            waitForTriage("Categorized", of: row, in: app)
            let schedule = row.staticTexts["task-schedule-label-group-categorized-inbox"]
            XCTAssertTrue(schedule.waitForExistence(timeout: 5))
            XCTAssertEqual(schedule.value as? String, "Someday")
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "task-section-someday").firstMatch.exists)
            app.typeKey("g", modifierFlags: [])
            app.typeKey("s", modifierFlags: [])
            XCTAssertTrue(app.staticTexts["Opened source: https://example.com/inbox"].waitForExistence(timeout: 5))
            app.typeKey("z", modifierFlags: [])
            waitForTriage("Inbox", of: row, in: app)
            XCTAssertTrue(app.buttons["task-triage-date-group-categorized-inbox"].waitForExistence(timeout: 5))
            XCTAssertEqual(chip.value as? String, "Category: Work Engineering")
            app.typeKey("b", modifierFlags: [])
            let dateInput = app.textFields["inbox-due-group-categorized-inbox-search"]
            XCTAssertTrue(dateInput.waitForExistence(timeout: 5))
            dateInput.typeText("nov 20 2026")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(dateInput.waitForNonExistence(timeout: 5))
            waitForTriage("Categorized", of: row, in: app)
            app.typeKey("e", modifierFlags: [])
            let title = app.textFields["task-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, "Group categorized inbox task")
            let someday = app.checkBoxes["task-someday"]
            XCTAssertEqual((someday.value as? NSNumber)?.intValue, 0)
            XCTAssertNotEqual(app.buttons["task-due"].value as? String, "No date")
            someday.click()
            waitForValue("No date", of: app.buttons["task-due"])
            app.buttons["task-start"].click()
            let start = app.textFields["task-start-search"]
            XCTAssertTrue(start.waitForExistence(timeout: 5))
            start.typeText("dec 18 2026")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(start.waitForNonExistence(timeout: 5))
            XCTAssertEqual((someday.value as? NSNumber)?.intValue, 0)
            someday.click()
            XCTAssertEqual((someday.value as? NSNumber)?.intValue, 1)
            app.sheets.buttons["Save"].click()
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))
            app.typeKey("e", modifierFlags: [])
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual((someday.value as? NSNumber)?.intValue, 1)
            XCTAssertEqual(app.buttons["task-due"].value as? String, "No date")
            XCTAssertNotEqual(app.buttons["task-start"].value as? String, "No date")
            app.buttons["task-start"].click()
            XCTAssertTrue(start.waitForExistence(timeout: 5))
            app.buttons["task-start-quick-none"].click()
            XCTAssertTrue(start.waitForNonExistence(timeout: 5))
            XCTAssertEqual((someday.value as? NSNumber)?.intValue, 0)
            XCTAssertTrue(app.staticTexts["task-date-triage-warning"].exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))
            app.typeKey("z", modifierFlags: [])
            app.typeKey("e", modifierFlags: [])
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual((someday.value as? NSNumber)?.intValue, 0)
            XCTAssertNotEqual(app.buttons["task-due"].value as? String, "No date")
            XCTAssertEqual(app.buttons["task-start"].value as? String, "No date")
            let source = app.textFields["task-source-url"]
            for _ in 0..<6 where !source.isHittable {
                app.sheets.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180)
            }
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertEqual(source.value as? String, "https://example.com/inbox")
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "task-triage-source-undo-\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func waitForTriage(_ state: String, of row: XCUIElement, in app: XCUIApplication) {
        wait(for: [expectation(for: NSPredicate(format: "label ENDSWITH %@", ", \(state)"), evaluatedWith: row)], timeout: 5)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: row.identifier).count, 1,
                       "A task must have only one native row after changing sections")
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement) {
        wait(for: [expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)], timeout: 5)
    }
}
