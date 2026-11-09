import XCTest

/// Wait for real content before capturing; a fixed launch delay can silently save a blank screen.
final class SmokeTests: XCTestCase {
    @MainActor
    func testScreensInBothAppearances() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            waitForText("Infra offsite", in: app)
            capture(app, "agenda-\(appearance)")

            app.tabBars.buttons["Tasks"].tap()
            waitForText("Renew VPN certificate", in: app)
            capture(app, "tasks-\(appearance)")
            app.tabBars.buttons["Settings"].tap()
            waitForText("Save and sync", in: app)
            capture(app, "settings-\(appearance)")
            app.terminate()

            let event = launch(appearance: appearance, sheet: "event")
            let join = event.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Join meeting")).firstMatch
            XCTAssertTrue(join.waitForExistence(timeout: 20))
            waitForText("Design review: scheduler v2", in: event)
            capture(event, "event-detail-\(appearance)")
            event.terminate()

            let draft = launch(appearance: appearance, tab: "tasks", sheet: "aitask")
            waitForText("How AI read it", in: draft)
            XCTAssertTrue(draft.buttons["Add"].exists)
            capture(draft, "task-draft-\(appearance)")
            draft.terminate()

            let picker = launch(appearance: appearance, sheet: "daypicker")
            waitForText("Go to Day", in: picker)
            XCTAssertTrue(picker.buttons["Done"].waitForExistence(timeout: 20))
            capture(picker, "day-picker-\(appearance)")
            picker.terminate()
        }

        let large = launch(largeText: true)
        waitForText("Infra offsite", in: large)
        capture(large, "agenda-large-text")
        large.tabBars.buttons["Tasks"].tap()
        waitForText("Renew VPN certificate", in: large)
        capture(large, "tasks-large-text")
        large.terminate()
    }

    @MainActor
    private func launch(appearance: String = "light", tab: String = "agenda", sheet: String? = nil, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiTab", tab, "-uiAppearance", appearance]
        if let sheet { app.launchArguments += ["-uiSheet", sheet] }
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            largeText ? "UICTContentSizeCategoryXXXL" : "UICTContentSizeCategoryL",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func waitForText(_ text: String, in app: XCUIApplication) {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Missing \(text)")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
