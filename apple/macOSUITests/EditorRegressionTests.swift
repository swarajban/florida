import XCTest

final class EditorRegressionTests: XCTestCase {
    @MainActor
    func testUnchangedEditorDoesNotConsumeUndoOrWrite() {
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiEditorDiagnostics", "YES"]
        app.launch()
        defer { app.terminate() }
        let diagnostics = app.staticTexts["editor-diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 15))
        let row = app.staticTexts["Renew VPN certificate"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let save = app.sheets.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Save")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        waitForValue("taskWrites=0 queueChanges=0 sounds=0 pendingRows=0 syncApplied=false", of: diagnostics)
        app.typeKey("z", modifierFlags: [])
        assertValueRemains("taskWrites=0 queueChanges=0 sounds=0 pendingRows=0 syncApplied=false", of: diagnostics)
        XCTAssertTrue(row.exists)
    }

    @MainActor
    func testEditedTaskCompletesWithOneWriteAndOneSoundInBothAppearances() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-demoData", "YES", "-uiAppearance", appearance, "-uiEditorDiagnostics", "YES",
                "-joy.completionSound", "YES", "-joy.completionBloom", "NO",
            ]
            app.launch()
            defer { app.terminate() }
            let diagnostics = app.staticTexts["editor-diagnostics"]
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 15))
            let initial = "taskWrites=0 queueChanges=0 sounds=0 pendingRows=0 syncApplied=false"
            waitForValue(initial, of: diagnostics)
            let originalTitle = "Renew VPN certificate"
            let row = app.staticTexts[originalTitle].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.click()
            let title = app.sheets.textFields.firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, originalTitle)
            title.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Edited VPN once")
            waitForValue("Edited VPN once", of: title)
            XCTAssertEqual(diagnostics.value as? String, initial)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(title.exists, "Escape must leave the title field without closing the editor")
            XCTAssertEqual(title.value as? String, "Edited VPN once")
            app.typeKey(.space, modifierFlags: [])
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))
            let completed = "taskWrites=1 queueChanges=1 sounds=1 pendingRows=1 syncApplied=false"
            waitForValue(completed, of: diagnostics)
            assertValueRemains(completed, of: diagnostics)
            XCTAssertFalse(row.exists)
            XCTAssertFalse(app.buttons["task-done-demo-task-vpn"].exists)

            app.typeKey("z", modifierFlags: [])
            XCTAssertTrue(row.waitForExistence(timeout: 5), "one undo must restore both the original title and its open state")
            XCTAssertTrue(app.buttons["task-done-demo-task-vpn"].waitForExistence(timeout: 5))
            let undone = "taskWrites=2 queueChanges=2 sounds=1 pendingRows=1 syncApplied=false"
            waitForValue(undone, of: diagnostics)
            row.click()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, originalTitle)
            XCTAssertTrue(app.sheets.buttons["Mark done"].exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))
            app.typeKey("z", modifierFlags: [])
            assertValueRemains(undone, of: diagnostics)
            XCTAssertTrue(row.exists, "completion and its edits must leave only one undo entry")
        }
    }

    @MainActor
    func testTitleCaretSurvivesSyncAndPointerPlacementInBothAppearances() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-demoData", "YES", "-uiAppearance", appearance, "-uiEditorDiagnostics", "YES",
                "-uiEditorSyncDuringTyping", "YES",
            ]
            app.launch()
            defer { app.terminate() }
            let diagnostics = app.staticTexts["editor-diagnostics"]
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 15))
            waitForValue("taskWrites=0 queueChanges=0 sounds=0 pendingRows=0 syncApplied=false", of: diagnostics)
            let row = app.staticTexts["Renew VPN certificate"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.click()
            let title = app.sheets.textFields.firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, "Renew VPN certificate")
            title.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeText("alpha bravo charlie")
            waitForValue("taskWrites=1 queueChanges=0 sounds=0 pendingRows=0 syncApplied=true", of: diagnostics)
            XCTAssertEqual(title.value as? String, "alpha bravo charlie", "a remote task update must not replace the draft")
            for _ in 0..<7 { app.typeKey(.leftArrow, modifierFlags: []) }
            app.typeText("green ")
            waitForValue("alpha bravo green charlie", of: title)
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
            for _ in "alpha bravo green " { app.typeKey(.rightArrow, modifierFlags: []) }
            app.typeText("red ")
            let savedTitle = "alpha bravo green red charlie"
            waitForValue(savedTitle, of: title)
            XCTAssertEqual(diagnostics.value as? String,
                           "taskWrites=1 queueChanges=0 sounds=0 pendingRows=0 syncApplied=true")
            let save = app.sheets.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Save")).firstMatch
            XCTAssertTrue(save.exists)
            XCTAssertTrue(save.isHittable)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "editor-caret-\(appearance)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            save.click()
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))
            waitForValue("taskWrites=2 queueChanges=1 sounds=0 pendingRows=1 syncApplied=true", of: diagnostics)
            let savedRow = app.staticTexts[savedTitle].firstMatch
            XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
            savedRow.click()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, savedTitle, "Save must persist the text produced by both caret placements")
            XCTAssertTrue(app.sheets.buttons["Mark done"].exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    func testDraftKeysAndEventResponseDoNotCompleteTasksInBothAppearances() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance, "-uiEditorDiagnostics", "YES"]
            app.launch()
            defer { app.terminate() }
            let diagnostics = app.staticTexts["editor-diagnostics"]
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 15))
            let initial = "taskWrites=0 queueChanges=0 sounds=0 pendingRows=0 syncApplied=false"
            waitForValue(initial, of: diagnostics)
            let row = app.staticTexts["Renew VPN certificate"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.click()
            let title = app.sheets.textFields.firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Unsaved VPN draft")
            waitForValue("Unsaved VPN draft", of: title)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(title.exists)
            let priority = app.buttons["task-priority"]
            XCTAssertEqual(priority.value as? String, "High")
            app.typeKey("p", modifierFlags: [])
            let prioritySearch = app.textFields["task-priority-search"]
            XCTAssertTrue(prioritySearch.waitForExistence(timeout: 5))
            app.typeText("Medium")
            waitForValue("Medium", of: prioritySearch)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(prioritySearch.waitForNonExistence(timeout: 5))
            waitForValue("Medium", of: priority)
            XCTAssertEqual(title.value as? String, "Unsaved VPN draft")
            XCTAssertEqual(diagnostics.value as? String, initial)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))
            XCTAssertTrue(row.exists)
            row.click()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, "Renew VPN certificate")
            XCTAssertEqual(priority.value as? String, "High")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))
            XCTAssertEqual(diagnostics.value as? String, initial)

            app.typeKey("/", modifierFlags: [])
            let search = app.textFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.typeText("Standup")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(search.waitForNonExistence(timeout: 5))
            app.typeKey(.return, modifierFlags: [])
            let edit = app.buttons["Edit…"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            let maybe = app.popovers.descendants(matching: .any).matching(NSPredicate(
                format: "(elementType == %d OR elementType == %d) AND label BEGINSWITH %@",
                Int(XCUIElement.ElementType.button.rawValue), Int(XCUIElement.ElementType.checkBox.rawValue), "Maybe")).firstMatch
            XCTAssertTrue(maybe.exists)
            XCTAssertEqual((maybe.value as? NSNumber)?.intValue, 0)
            XCTAssertEqual(diagnostics.value as? String, initial)
            app.typeKey("r", modifierFlags: [])
            app.typeKey("m", modifierFlags: [])
            let responded = "taskWrites=0 queueChanges=1 sounds=0 pendingRows=1 syncApplied=false"
            waitForValue(responded, of: diagnostics)
            wait(for: [expectation(for: NSPredicate(format: "value == 1"), evaluatedWith: maybe)], timeout: 5)
            XCTAssertTrue(edit.exists)
            app.typeKey("r", modifierFlags: [])
            app.typeKey("m", modifierFlags: [])
            assertValueRemains(responded, of: diagnostics)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement) {
        wait(for: [expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)], timeout: 5)
    }

    @MainActor
    private func assertValueRemains(_ value: String, of element: XCUIElement) {
        let changed = expectation(for: NSPredicate(format: "value != %@", value), evaluatedWith: element)
        changed.isInverted = true
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(element.value as? String, value)
    }
}
