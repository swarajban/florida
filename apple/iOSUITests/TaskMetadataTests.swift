import XCTest

final class TaskMetadataTests: XCTestCase {
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
        for _ in 0..<4 {
            if element.isHittable { return }
            app.collectionViews["task-editor-form"].swipeUp()
        }
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
