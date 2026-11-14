import AppKit
import XCTest

final class MacModeStateTests: XCTestCase {
    @MainActor
    func testDateQueryKeepsTextWhenMovingTheCaret() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        openTask(app)
        app.buttons["task-due"].click()
        let search = app.textFields["task-due-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeText("nov 25")
        waitForValue("nov 25", of: search)
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "nov 25")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "nov 25")
    }

    @MainActor
    func testClickingTitleFromADateSelectorKeepsTheNewFocus() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        openTask(app)
        app.buttons["task-due"].click()
        let search = app.textFields["task-due-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let title = app.textFields["task-title"]
        title.click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Pointer focus survives")
        XCTAssertEqual(title.value as? String, "Pointer focus survives")
    }

    @MainActor
    func testGoToDateStartsWithAnEditableQuery() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.typeKey("g", modifierFlags: [])
        app.typeKey("d", modifierFlags: [])
        let search = app.textFields["go-to-date-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeText("nov 20")
        XCTAssertEqual(search.value as? String, "nov 20")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        app.sheets.buttons["Go"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testSettingsShortcutsDoNotChangeTheBackgroundTask() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        openTask(app)
        let priority = app.buttons["task-priority"]
        XCTAssertTrue(priority.waitForExistence(timeout: 5))
        let original = priority.value as? String
        XCTAssertNotEqual(original, "ASAP")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["task-title"].waitForNonExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let settings = element("settings-tabs", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(priority.waitForExistence(timeout: 5))
        XCTAssertEqual(priority.value as? String, original)
    }

    @MainActor
    func testCommandPaletteReplacesTheEventPopoverTarget() {
        continueAfterFailure = false
        let app = launch(extra: ["-uiHeldKeyDiagnostics", "YES"])
        defer { app.terminate() }
        openEvent("Design review", in: app)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["palette-input"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["interaction-event-target"].value as? String, "none")
        XCTAssertFalse(app.buttons["Edit…"].exists)
    }

    @MainActor
    func testAvailabilityDoesNotOpenAnUnownedBriefOrProjectSheet() {
        continueAfterFailure = false
        let app = launch(taskFixture: false)
        defer { app.terminate() }
        openAvailability(app)
        let preview = app.staticTexts["availability-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        for id in ["open-brief", "open-projects"] {
            app.buttons[id].click()
            XCTAssertFalse(app.sheets.firstMatch.exists)
            XCTAssertTrue(preview.exists)
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testEventCorrectionHandoffReturnsFocusToTheSentence() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.typeKey("c", modifierFlags: .shift)
        let input = app.textFields["event-quick-add-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let sentence = "Focus handoff tomorrow at 9am"
        app.typeText(sentence)
        waitForValue(sentence, of: input)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(element("event-quick-add-date-picker", in: app).waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(element("event-quick-add-start", in: app).waitForExistence(timeout: 5))
        app.buttons["event-quick-add-correction-done"].click()
        XCTAssertTrue(app.buttons["event-quick-add-correction-done"].waitForNonExistence(timeout: 5))
        app.typeText(" extra")
        XCTAssertEqual(input.value as? String, sentence + " extra")
    }

    @MainActor
    func testReturnAcceptsAIReviewInsteadOfSavingTheRawSentence() {
        continueAfterFailure = false
        let app = launch(extra: ["-uiInteractionAIReply", "YES"])
        defer { app.terminate() }
        openAIReview(app)
        app.typeKey(.return, modifierFlags: [])
        let title = app.textFields["task-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Parsed audit review")
        XCTAssertFalse(app.buttons["Use this"].exists)
    }

    @MainActor
    func testAcceptedAIFieldsReachTheEditorDraft() {
        continueAfterFailure = false
        let app = launch(extra: ["-uiInteractionAIReply", "YES"])
        defer { app.terminate() }
        openAIReview(app)
        app.buttons["Use this"].click()
        XCTAssertEqual(app.textFields["task-title"].value as? String, "Parsed audit review")
        app.sheets.scrollViews.firstMatch.swipeUp()
        let context = app.buttons["task-context"]
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        XCTAssertEqual(context.value as? String, "Errand")
        XCTAssertNotEqual(app.buttons["task-project"].value as? String, "None")
        XCTAssertEqual(app.buttons["task-attention"].value as? String, "Can run in parallel")
    }

    @MainActor
    func testCategoryFailureIsVisibleInsideItsSheet() {
        continueAfterFailure = false
        let app = launch(taskFixture: false, extra: ["-demoUnsynced", "YES"])
        defer { app.terminate() }
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["New Category…"].click()
        let name = app.textFields["new-category-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.typeText("Missing schedule category")
        app.sheets.buttons["Create"].click()
        XCTAssertTrue(name.exists)
        XCTAssertTrue(app.sheets.staticTexts["Nothing has synced yet — sync with the server first"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testEscapeDuringAnActualDragDoesNotDropTheEvent() {
        continueAfterFailure = false
        let app = launch(taskFixture: false)
        defer { app.terminate() }
        let block = standupPoint(app)
        app.buttons["mode-arm-drag-escape"].click()
        block.press(forDuration: 0.3, thenDragTo: block.withOffset(CGVector(dx: 0, dy: 90)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertEqual(app.staticTexts["mode-drag-injection"].value as? String, "sent")
        XCTAssertFalse(app.sheets.buttons["This Event"].exists)
        XCTAssertFalse(app.sheets.buttons["Move Event"].exists)
        XCTAssertEqual(app.staticTexts["mode-active-drag"].value as? String, "none")
    }

    @MainActor
    func testSwitchingViewDuringAnActualDragClearsItsGhost() {
        continueAfterFailure = false
        let app = launch(taskFixture: false)
        defer { app.terminate() }
        let block = standupPoint(app)
        app.buttons["mode-arm-drag-month"].click()
        block.press(forDuration: 0.3, thenDragTo: block.withOffset(CGVector(dx: 0, dy: 90)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertEqual(app.staticTexts["mode-drag-injection"].value as? String, "sent")
        waitForValue("month", of: app.staticTexts["mode-calendar-view"])
        app.typeKey("w", modifierFlags: [])
        XCTAssertEqual(app.staticTexts["mode-active-drag"].value as? String, "none")
    }

    @MainActor
    func testSuggestionRowsRefreshSelectionAndJumpLabels() {
        continueAfterFailure = false
        let app = launch(taskFixture: false)
        defer { app.terminate() }
        let first = element("suggestion-row-demo-pick-taxes", in: app)
        let second = element("suggestion-row-demo-pick-funds", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        first.staticTexts.firstMatch.click()
        XCTAssertTrue(app.textFields["task-title"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["task-title"].waitForNonExistence(timeout: 5))
        waitForValue("Selected", of: first)
        second.staticTexts.firstMatch.click()
        XCTAssertTrue(app.textFields["task-title"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["task-title"].waitForNonExistence(timeout: 5))
        waitForValue("Not selected", of: first)
        waitForValue("Selected", of: second)
        app.typeKey("f", modifierFlags: [])
        let badge = element("suggestion-jump-demo-pick-taxes", in: app)
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testAllDayBarsRefreshSelectionAndJumpLabels() {
        continueAfterFailure = false
        let app = launch(taskFixture: false)
        defer { app.terminate() }
        let first = element("all-day-row-demo-event-offsite", in: app)
        let second = element("all-day-row-demo-event-ooo", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        first.click()
        waitForValue("Selected", of: first)
        second.click()
        waitForValue("Not selected", of: first)
        waitForValue("Selected", of: second)
        app.typeKey("f", modifierFlags: [])
        let badge = element("event-jump-demo-event-offsite", in: app)
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testLongSmartAddListKeepsExactlyOneVisibleHighlight() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.typeKey("c", modifierFlags: [])
        let input = app.textFields["palette-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.typeText("Probe ^")
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "smart-add-suggestion-^"))
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<7 { app.typeKey(.downArrow, modifierFlags: []) }
        let highlighted = choices.allElementsBoundByIndex.filter { $0.isHittable && $0.value as? String == "Highlighted" }
        XCTAssertEqual(highlighted.count, 1)
        XCTAssertNotEqual(highlighted.first?.identifier, "smart-add-suggestion-^today")
        app.typeKey(.upArrow, modifierFlags: [])
        let moved = choices.allElementsBoundByIndex.filter { $0.isHittable && $0.value as? String == "Highlighted" }
        XCTAssertEqual(moved.count, 1)
        XCTAssertNotEqual(moved.first?.identifier, highlighted.first?.identifier)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertNotEqual(input.value as? String, "Probe ^")
        XCTAssertTrue((input.value as? String)?.hasSuffix(" ") == true)
    }

    @MainActor
    func testResourceKeycapNarrowsInsideItsExistingTile() {
        continueAfterFailure = false
        let app = launch(extra: ["-uiInteractionManyResources", "YES"])
        defer { app.terminate() }
        openEvent("Design review", in: app)
        let key = element("mode-resource-key-https://example.com/interaction-resource/1", in: app)
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        let label = key.value as? String ?? ""
        XCTAssertEqual(label.count, 2)
        app.typeKey(String(label.prefix(1)), modifierFlags: [])
        XCTAssertTrue(app.buttons["Edit…"].exists)
        waitForValue(String(label.dropFirst()), of: key)
        app.typeKey(String(label.suffix(1)), modifierFlags: [])
        let opened = app.staticTexts.matching(NSPredicate(format: "value == %@", "Opened resource: https://example.com/interaction-resource/1")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 5))
    }

    @MainActor
    func testHidingTheTaskPaneRemovesUnmountedVisibilityRegistrations() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.buttons["mode-snapshot-rows"].click()
        let snapshot = app.staticTexts["mode-visible-rows"]
        XCTAssertNotEqual(snapshot.value as? String, "none")
        XCTAssertNotEqual(snapshot.value as? String, "unread")
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.scrollViews["task-pane-scroll"].waitForNonExistence(timeout: 5))
        app.buttons["mode-snapshot-rows"].click()
        XCTAssertEqual(snapshot.value as? String, "none")
    }

    @MainActor
    func testProgressReturnSubmitsOneWrite() {
        continueAfterFailure = false
        let app = launch(extra: ["-uiEditorDiagnostics", "YES"])
        defer { app.terminate() }
        openTask(app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["task-title"].waitForNonExistence(timeout: 5))
        app.typeKey(.space, modifierFlags: .shift)
        let minutes = app.sheets.textFields.firstMatch
        XCTAssertTrue(minutes.waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("5")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(minutes.waitForNonExistence(timeout: 5))
        waitForValue("taskWrites=1 queueChanges=1 sounds=0 pendingRows=1 syncApplied=false",
                     of: app.staticTexts["editor-diagnostics"])
    }

    @MainActor
    private func launch(taskFixture: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiAppearance", "dark", "-demoNow", "2026-11-13T17:00:00Z",
                               "-uiInteractionModeDiagnostics", "YES", "-uiRecordResourceOpens", "YES"] + extra
        if taskFixture { app.launchArguments += ["-uiTaskDateDemo", "YES", "-uiTaskDateSelectionDemo", "YES"] }
        app.launch()
        XCTAssertTrue(app.buttons["mode-snapshot-rows"].waitForExistence(timeout: 15))
        if taskFixture {
            let grouping = element("task-grouping-menu", in: app)
            XCTAssertTrue(grouping.waitForExistence(timeout: 5))
            grouping.click()
            app.menuItems["Due date"].click()
            XCTAssertTrue(element("task-row-date-updated", in: app).waitForExistence(timeout: 5))
        }
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func openTask(_ app: XCUIApplication) {
        element("task-row-date-updated", in: app).staticTexts["Updated account task"].click()
        XCTAssertTrue(app.textFields["task-title"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openEvent(_ title: String, in app: XCUIApplication) {
        app.typeKey("/", modifierFlags: [])
        let input = app.textFields["palette-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.typeText(title)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Edit…"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openAIReview(_ app: XCUIApplication) {
        app.typeKey("c", modifierFlags: [])
        let input = app.textFields["palette-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.typeText("Review a loose request")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.buttons["Use this"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openAvailability(_ app: XCUIApplication) {
        app.typeKey("k", modifierFlags: .command)
        let input = app.textFields["palette-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.typeText("Share availability")
        app.typeKey(.return, modifierFlags: [])
    }

    @MainActor
    private func standupPoint(_ app: XCUIApplication) -> XCUICoordinate {
        openEvent("Standup", in: app)
        let frame = app.popovers.firstMatch.frame
        let window = app.windows.firstMatch
        let windowFrame = window.frame
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["Edit…"].waitForNonExistence(timeout: 5))
        return window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX - windowFrame.minX - 40, dy: frame.midY - windowFrame.minY))
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement) {
        wait(for: [expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)], timeout: 5)
    }
}
