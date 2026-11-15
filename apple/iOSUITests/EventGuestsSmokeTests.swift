import XCTest

final class EventGuestsSmokeTests: XCTestCase {
    @MainActor
    func testPendingGuestPersistsOnSave() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiTab", "agenda", "-uiSheet", "event", "-uiAppearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15))
        app.buttons["Edit"].tap()
        let input = app.textFields["event-guest-input"]
        for _ in 0..<5 where !input.isHittable { app.swipeUp() }
        XCTAssertTrue(input.isHittable)
        input.tap()
        input.typeText("newguest@acme.com")
        capture(app, "event-guests-pending")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForNonExistence(timeout: 5))
        app.buttons["Edit"].tap()
        let remove = app.buttons["Remove newguest@acme.com"]
        for _ in 0..<5 where !remove.isHittable { app.swipeUp() }
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "event-guests-saved"
        proof.lifetime = .keepAlways
        add(proof)
        print("Saved guest exists=\(remove.exists) frame=\(remove.frame); input frame=\(input.frame)")
        XCTAssertTrue(remove.exists)
        XCTAssertTrue(app.staticTexts["newguest@acme.com"].exists)
        app.terminate()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
