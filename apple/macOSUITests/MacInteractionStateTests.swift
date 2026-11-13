import AppKit
import XCTest

final class MacInteractionStateTests: XCTestCase {
    @MainActor
    func testHeldTitleShortcutDoesNotReplaceTheTitle() {
        continueAfterFailure = false
        let app = launch("dark")
        defer { app.terminate() }
        row("date-updated", in: app).staticTexts["Updated account task"].click()
        let title = app.textFields["task-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        hold("t", in: app)
        XCTAssertEqual(title.value as? String, "Updated account task")
    }

    @MainActor
    func testHeldDeleteDoesNotDeleteTheNextTask() {
        continueAfterFailure = false
        let app = launch("dark")
        defer { app.terminate() }
        selectFirstTask(in: app)
        hold("x", in: app)
        XCTAssertTrue(row("date-updated", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(row("date-other", in: app).exists)
    }

    @MainActor
    func testHeldUndoDoesNotDrainUndoHistory() {
        continueAfterFailure = false
        let app = launch("dark")
        defer { app.terminate() }
        selectFirstTask(in: app)
        app.typeKey("x", modifierFlags: [])
        XCTAssertTrue(row("date-updated", in: app).waitForNonExistence(timeout: 5))
        app.typeKey("x", modifierFlags: [])
        XCTAssertTrue(row("date-other", in: app).waitForNonExistence(timeout: 5))
        hold("z", in: app)
        XCTAssertTrue(row("date-other", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(row("date-updated", in: app).exists)
    }

    @MainActor
    func testHeldPaletteShortcutDoesNotTypeIntoTheInput() {
        continueAfterFailure = false
        for key in ["c", "/"] {
            let app = launch("dark")
            defer { app.terminate() }
            hold(key, in: app)
            let input = app.textFields["palette-input"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertEqual(input.value as? String, "")
        }
    }

    @MainActor
    func testHeldResourcePrefixDoesNotChooseALink() {
        continueAfterFailure = false
        let app = launch("dark", extra: ["-uiInteractionManyResources", "YES"])
        defer { app.terminate() }
        openDesignReview(in: app)
        hold("1", in: app)
        XCTAssertTrue(app.buttons["Edit…"].exists)
        XCTAssertFalse(openedResource(in: app).exists)
        app.typeKey("1", modifierFlags: [])
        XCTAssertTrue(openedResource(in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testPrefixesExpireWithoutAnotherKeyAndClearOnClick() {
        continueAfterFailure = true
        let app = launch("dark")
        defer { app.terminate() }
        for prefix in ["g", "r"] {
            app.typeKey(prefix, modifierFlags: [])
            let hint = app.staticTexts["\(prefix) …"]
            XCTAssertTrue(hint.waitForExistence(timeout: 5))
            XCTAssertTrue(hint.waitForNonExistence(timeout: 3))
            app.typeKey(.escape, modifierFlags: [])
        }
        app.typeKey("g", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["g …"].waitForExistence(timeout: 5))
        row("date-updated", in: app).staticTexts["Updated account task"].click()
        XCTAssertTrue(app.buttons["task-due"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["g …"].exists)
    }

    @MainActor
    func testHidingTheOnlySurfaceForASelectionClearsItsTarget() {
        continueAfterFailure = false
        let app = launch("dark")
        defer { app.terminate() }
        selectFirstTask(in: app)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.scrollViews["task-pane-scroll"].waitForNonExistence(timeout: 5))
        let selection = app.staticTexts["interaction-selection"]
        XCTAssertEqual(selection.value as? String, "none")
        app.typeKey("x", modifierFlags: [])
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(row("date-updated", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testHeaderNavigationEndsJumpMode() {
        continueAfterFailure = false
        let app = launch("dark")
        defer { app.terminate() }
        app.typeKey("f", modifierFlags: [])
        let badge = app.staticTexts["task-jump-date-updated"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        app.radioButtons["Month"].click()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5))
        app.typeKey("f", modifierFlags: [])
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        app.buttons["Today"].click()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testNavigationDismissesTheOffscreenEventTarget() {
        continueAfterFailure = false
        let app = launch("dark")
        defer { app.terminate() }
        openDesignReview(in: app)
        app.menuBars.menuBarItems["Go"].click()
        app.menuItems["Next Week"].click()
        XCTAssertTrue(app.buttons["Edit…"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["interaction-event-target"].value as? String, "none")
        selectFirstTask(in: app)
        app.typeKey("1", modifierFlags: [])
        app.typeKey("1", modifierFlags: [])
        XCTAssertFalse(openedResource(in: app).exists)
        app.typeKey("x", modifierFlags: [])
        XCTAssertFalse(app.buttons["Delete Event"].exists)
        XCTAssertTrue(row("date-updated", in: app).waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testShieldPopoverCopiesTheEventInsteadOfTheBackgroundTask() {
        continueAfterFailure = false
        let app = launch("dark")
        defer { app.terminate() }
        selectFirstTask(in: app)
        let shield = app.buttons["day-blocking-2026-11-13-demo-event-holiday"]
        XCTAssertTrue(shield.waitForExistence(timeout: 5))
        shield.click()
        XCTAssertTrue(app.staticTexts["event-blocks-day-effective-demo-event-holiday"].waitForExistence(timeout: 5))
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string),
                       "https://calendar.google.com/calendar/event?eid=demo-event-holiday")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2))
    }

    @MainActor
    func testCheckoutDetailDoesNotClaimTheOpenDayIsBlocked() {
        continueAfterFailure = false
        let app = launch("dark", extra: ["-uiInteractionTripDemo", "YES"])
        defer { app.terminate() }
        let title = app.staticTexts["Interaction trip"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        let reason = app.staticTexts["event-blocking-reason-interaction-trip"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        XCTAssertTrue((reason.value as? String)?.contains("last day open") == true)
        XCTAssertNotEqual(app.staticTexts["event-blocks-day-effective-interaction-trip"].value as? String,
                          "Blocks your day")
    }

    @MainActor
    private func launch(_ appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance,
                               "-demoNow", "2026-11-13T17:00:00Z", "-uiHeldKeyDiagnostics", "YES",
                               "-uiTaskDateDemo", "YES", "-uiTaskDateSelectionDemo", "YES",
                               "-uiRecordResourceOpens", "YES"] + extra
        app.launch()
        let grouping = app.descendants(matching: .any).matching(identifier: "task-grouping-menu").firstMatch
        XCTAssertTrue(grouping.waitForExistence(timeout: 15))
        grouping.click()
        app.menuItems["Due date"].click()
        XCTAssertTrue(row("date-updated", in: app).waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func selectFirstTask(in app: XCUIApplication) {
        app.typeKey("g", modifierFlags: [])
        app.typeKey("t", modifierFlags: [])
        app.typeKey("g", modifierFlags: [])
        app.typeKey("g", modifierFlags: [])
        let selected = row("date-updated", in: app)
        wait(for: [expectation(for: NSPredicate(format: "label == %@", "Selected task, Updated account task"),
                              evaluatedWith: selected)], timeout: 5)
    }

    @MainActor
    private func hold(_ key: String, in app: XCUIApplication) {
        let button = app.buttons["inject-held-\(key)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        XCTAssertTrue(app.staticTexts["held-key-finished-\(key)"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func row(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "task-row-\(id)").firstMatch
    }

    @MainActor
    private func openDesignReview(in app: XCUIApplication) {
        app.typeKey("/", modifierFlags: [])
        let input = app.textFields["palette-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("Design review")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Edit…"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openedResource(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Opened resource:")).firstMatch
    }
}
