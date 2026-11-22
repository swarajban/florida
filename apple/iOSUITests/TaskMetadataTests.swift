import XCTest

final class TaskMetadataTests: XCTestCase {
    @MainActor
    func testMustHappenThatDayPersistsInEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-demoData", "YES", "-uiTaskGroupingDemo", "YES", "-demoNow", "2026-11-18T12:00:00Z",
            "-uiTab", "tasks", "-uiAppearance", "light",
        ]
        let toggle = app.switches["task-must-happen-on-day"]
        addTeardownBlock { @MainActor in
            self.capture(app, "must-happen-that-day")
            print("Required day toggle: exists=\(toggle.exists), frame=\(toggle.frame), value=\(String(describing: toggle.value))")
            app.terminate()
        }
        app.launch()
        let row = app.buttons["tasks-row-group-overdue"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        let control = toggle.switches.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        print("Required day tap: row=\(toggle.frame), control=\(control.frame), enabled=\(control.isEnabled)")
        control.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let editor = app.navigationBars["Edit Task"]
        editor.buttons["Save"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1")
    }

    @MainActor
    func testTagsAndWaitingEditAndFilter() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-demoData", "YES", "-uiTaskGroupingDemo", "YES", "-demoNow", "2026-11-18T12:00:00Z",
            "-uiTab", "tasks", "-uiAppearance", "light",
        ]
        app.launch()
        let row = app.buttons["tasks-row-group-inbox"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let waiting = app.textFields["task-waiting-on"]
        reveal(waiting, in: app)
        XCTAssertTrue(waiting.isHittable)
        waiting.tap()
        waiting.typeText("Alice")
        let tags = app.textFields["task-tags-input"]
        reveal(tags, in: app)
        tags.tap()
        tags.typeText("CLIENT, review")
        app.buttons["task-tags-add"].tap()
        capture(app, "tags-waiting-editor")
        XCTAssertTrue(app.buttons["Remove tag client"].exists)
        app.navigationBars["Edit Task"].buttons["Save"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture(app, "tags-waiting-tasks")
        XCTAssertTrue(row.label.contains("Waiting: Alice") && row.label.contains("#client"))
        let search = app.textFields["tasks-metadata-search"]
        search.tap()
        search.typeText("#client Alice\n")
        XCTAssertTrue(row.exists)
        XCTAssertFalse(app.buttons["tasks-row-group-categorized-inbox"].exists)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable { return }
            app.collectionViews["task-editor-form"].swipeUp()
        }
        if element.isHittable { return }
        capture(app, "metadata-control-state")
        print("METADATA_CONTROL \(element.debugDescription) frame=\(element.frame)")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
