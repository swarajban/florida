import XCTest

final class ShareCaptureTests: XCTestCase {
    @MainActor
    func testLiteralTitleAndSingleLocalSave() {
        let app = launch(title: "Fix crash #123")
        XCTAssertTrue(app.buttons["share-add"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["share-preview"].label.contains("Fix crash #123"))
        XCTAssertEqual(app.staticTexts["share-destination"].label, "Goes to Inbox")
        XCTAssertTrue(app.staticTexts["share-source"].exists)
        capture(app, "share-literal-preview")
        let add = app.buttons["share-add"]
        XCTAssertTrue(NSPredicate(format: "enabled == true").evaluate(with: add) || XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)], timeout: 10) == .completed)
        add.doubleTap()
        let result = app.staticTexts["share-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "Writes: 1 · Fix crash #123 · https://example.com/article")
    }

    @MainActor
    func testEditingGrammarAndCancelWritesNothing() {
        let app = launch(title: "Notes // draft")
        XCTAssertTrue(app.staticTexts["share-preview"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["share-preview"].label, "Notes // draft")
        let input = app.textFields["share-input"].exists ? app.textFields["share-input"] : app.textViews["share-input"]
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Notes // draft".count) + "Notes #work ^someday // draft")
        XCTAssertEqual(app.staticTexts["share-preview"].label, "Notes")
        XCTAssertTrue(app.staticTexts["share-notes"].label.contains("draft"))
        XCTAssertEqual(app.buttons["share-category"].label, "Work")
        XCTAssertTrue(app.staticTexts["share-destination"].label.contains("skips Inbox"))
        capture(app, "share-edited-preview")
        app.buttons["share-cancel"].tap()
        XCTAssertTrue(app.staticTexts["share-result"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["share-result"].label.contains("Writes: 0 · Cancelled"))
    }

    @MainActor
    private func launch(title: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiShareCapture", "YES", "-uiShareTitle", title]
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
