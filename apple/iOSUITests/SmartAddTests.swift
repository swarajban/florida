import XCTest

final class SmartAddTests: XCTestCase {
    @MainActor
    func testFourSuggestionRowsRemainVisible() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let input = openComposer(app)
            input.typeText("Compact capture #")
            let categories = app.descendants(matching: .any)["quick-add-category-choices"]
            XCTAssertTrue(categories.waitForExistence(timeout: 5))
            let symbol = app.buttons["quick-add-symbol-^"]
            let categoryRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quick-add-category-"))
            assertSuggestionLayout(app, input: input, rows: categoryRows, list: categories, above: symbol)
            capture(app, "smart-add-visible-category-input-\(appearance)")
            app.buttons["quick-add-category-inbox"].tap()
            input.typeText(" !")
            let priorities = app.descendants(matching: .any)["quick-add-suggestions"]
            XCTAssertTrue(priorities.waitForExistence(timeout: 5))
            let priorityRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quick-add-suggestion-!"))
            assertSuggestionLayout(app, input: input, rows: priorityRows, list: priorities, above: symbol)
            XCTAssertTrue(app.buttons["quick-add-shortcut-hint"].isHittable)
            XCTAssertGreaterThanOrEqual(input.frame.minY, app.navigationBars["New Task"].frame.maxY)
            XCTAssertLessThanOrEqual(input.frame.maxY, priorities.frame.minY)
            capture(app, "smart-add-visible-priority-input-\(appearance)")
            app.buttons["quick-add-shortcut-hint"].tap()
            let help = app.staticTexts["quick-add-help-content"]
            XCTAssertTrue(help.waitForExistence(timeout: 5))
            capture(app, "smart-add-help-\(appearance)")
            app.buttons["quick-add-help-done"].tap()
            XCTAssertTrue(help.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            input.typeText("2")
            app.typeKey(.tab, modifierFlags: [])
            XCTAssertEqual(input.value as? String, "Compact capture !2 ")
            let longDraft = String(repeating: "Keep the current line visible while editing ", count: 5)
            app.buttons["Clear draft"].tap()
            input.typeText(longDraft + "#")
            XCTAssertTrue(categories.waitForExistence(timeout: 5))
            assertSuggestionLayout(app, input: input, rows: categoryRows, list: categories, above: symbol)
            XCTAssertEqual(input.value as? String, longDraft + "#")
            capture(app, "smart-add-caret-category-\(appearance)")
            app.buttons["Clear draft"].tap()
            input.typeText(longDraft + "!")
            XCTAssertTrue(priorities.waitForExistence(timeout: 5))
            assertSuggestionLayout(app, input: input, rows: priorityRows, list: priorities, above: symbol)
            XCTAssertEqual(input.value as? String, longDraft + "!")
            capture(app, "smart-add-caret-priority-\(appearance)")
            app.terminate()
        }
        let app = launch("light", unsynced: true)
        defer { app.terminate() }
        let input = openComposer(app)
        input.typeText("Unsynced capture #new-category")
        let create = app.buttons["quick-add-create-category"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let error = app.staticTexts["Nothing has synced yet. Sync with the server first."]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.isHittable)
        let choices = app.descendants(matching: .any)["quick-add-category-choices"]
        XCTAssertTrue(create.isHittable)
        XCTAssertGreaterThanOrEqual(error.frame.minY, input.frame.maxY)
        XCTAssertLessThanOrEqual(error.frame.maxY, choices.frame.minY)
        XCTAssertEqual(input.value as? String, "Unsynced capture #new-category")
        assertVisibleCaret(app, input: input, list: choices)
        capture(app, "smart-add-category-error-visible")
    }

    @MainActor
    func testAmbiguousCategoryChoicesStayAboveSymbolButtons() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let input = openComposer(app)
            input.typeText("Ambiguous capture #work #literal")
            let infosec = app.buttons["quick-add-category-demo-infosec"]
            XCTAssertTrue(infosec.waitForExistence(timeout: 5))
            let symbol = app.buttons["quick-add-symbol-^"]
            XCTAssertTrue(infosec.isHittable)
            XCTAssertLessThanOrEqual(infosec.frame.maxY, symbol.frame.minY)
            capture(app, "smart-add-category-choice-\(appearance)")
            infosec.tap()
            let destination = app.buttons["quick-add-category"]
            XCTAssertTrue(destination.waitForExistence(timeout: 5))
            XCTAssertTrue(destination.label.contains("Work Infosec"))
            XCTAssertEqual(input.value as? String, "Ambiguous capture #work #literal")
            XCTAssertTrue(app.buttons["quick-add-save"].isEnabled)
            app.buttons["quick-add-save"].tap()
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testResolverAndSymbolKeysUseVisibleChoices() {
        continueAfterFailure = false
        let app = launch("light", directEscape: true)
        defer { app.terminate() }
        let input = openComposer(app)
        input.typeText("Keyboard unresolved #not-a-category ^tom")
        XCTAssertTrue(app.buttons["quick-add-suggestion-^tomorrow"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["quick-add-create-category"].exists)
        input.typeText("\n")
        XCTAssertEqual(input.value as? String, "Keyboard unresolved #not-a-category ^tomorrow ")
        XCTAssertTrue(app.buttons["quick-add-create-category"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["quick-add-suggestion-^tomorrow"].exists)
        invokeRegisteredEscape(in: app, input: input)
        XCTAssertTrue(app.buttons["quick-add-create-category"].waitForNonExistence(timeout: 5), input.label)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        input.typeText(" ")
        XCTAssertTrue(app.buttons["quick-add-use-inbox"].waitForExistence(timeout: 5))
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(app.buttons["quick-add-save"].isEnabled)
        XCTAssertTrue(app.buttons["quick-add-category"].label.contains("Inbox"))
        app.buttons["Clear draft"].tap()
        input.typeText("Keyboard category #work")
        let engineering = app.buttons["quick-add-category-demo-eng"]
        XCTAssertTrue(engineering.waitForExistence(timeout: 5))
        XCTAssertTrue(engineering.isSelected)
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons["quick-add-category-demo-infosec"].isSelected)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(input.value as? String, "Keyboard category #Work-Infosec ")
        XCTAssertTrue(app.buttons["quick-add-category"].label.contains("Work Infosec"))
        XCTAssertTrue(app.buttons["quick-add-save"].isEnabled)
    }

    @MainActor
    func testLocalSuggestionsAndSeveralTokens() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let input = openComposer(app)
            input.typeText("Smart capture")
            app.buttons["quick-add-symbol-^"].tap()
            XCTAssertEqual(input.value as? String, "Smart capture ^")
            input.typeText("tom")
            let tomorrow = app.buttons["quick-add-suggestion-^tomorrow"]
            XCTAssertTrue(tomorrow.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["quick-add-suggestion-^today"].exists)
            capture(app, "smart-add-suggestions-\(appearance)")
            input.typeText("\n")
            XCTAssertTrue(input.exists, "Return completes a suggestion without saving")
            XCTAssertEqual(input.value as? String, "Smart capture ^tomorrow ")
            app.buttons["quick-add-symbol-!"].tap()
            input.typeText("2")
            app.typeKey(.tab, modifierFlags: [])
            XCTAssertTrue(input.exists)
            XCTAssertTrue((input.value as? String)?.contains("!2 ") == true)
            app.buttons["quick-add-symbol-="].tap()
            input.typeText("45")
            app.buttons["quick-add-suggestion-=45"].tap()
            app.buttons["quick-add-symbol-@"].tap()
            input.typeText("home")
            app.buttons["quick-add-suggestion-@home"].tap()
            app.buttons["quick-add-symbol-#"].tap()
            input.typeText("home")
            app.buttons["quick-add-suggestion-#demo-home"].tap()
            input.typeText("#q4 ")
            app.buttons["quick-add-symbol-~"].tap()
            input.typeText("tod")
            app.buttons["quick-add-suggestion-~today"].tap()
            app.buttons["quick-add-symbol-//"].tap()
            input.typeText("Check the draft")
            XCTAssertEqual(app.staticTexts["quick-add-title"].label, "Smart capture #q4")
            XCTAssertTrue(app.buttons["quick-add-category"].label.contains("Home"))
            app.buttons["Details"].tap()
            XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["Title"].value as? String, "Smart capture #q4")
            let notes = app.descendants(matching: .any)["task-notes"]
            XCTAssertTrue(notes.waitForExistence(timeout: 5))
            XCTAssertEqual(notes.value as? String, "Check the draft")
            XCTAssertTrue(app.buttons["task-category"].label.contains("Home"))
            app.buttons["task-editor-cancel"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            app.buttons["quick-add-save"].tap()
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Smart capture #q4"))
            for _ in 0..<8 where !saved.firstMatch.isHittable
                || saved.firstMatch.frame.maxY > app.tabBars.firstMatch.frame.minY { app.swipeUp() }
            XCTAssertTrue(saved.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(saved.count, 1)
            app.buttons["New task"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertEqual(input.value as? String, "")
            app.terminate()
        }
    }

    @MainActor
    func testRecurrenceSurvivesDetailsAndSavesOnce() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let input = openComposer(app)
            input.typeText("Weekly smart review #home ")
            app.buttons["quick-add-symbol-*"].tap()
            input.typeText("week")
            app.buttons["quick-add-suggestion-*weekly"].tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Every week")).firstMatch.exists)
            app.buttons["Details"].tap()
            XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["Title"].value as? String, "Weekly smart review")
            let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Every week")).firstMatch
            for _ in 0..<8 where !summary.isHittable { app.swipeUp() }
            XCTAssertTrue(summary.waitForExistence(timeout: 5))
            app.buttons["Add"].tap()
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weekly smart review"))
            for _ in 0..<8 where !saved.firstMatch.isHittable
                || saved.firstMatch.frame.maxY > app.tabBars.firstMatch.frame.minY { app.swipeUp() }
            XCTAssertTrue(saved.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(saved.count, 1)
            saved.firstMatch.tap()
            XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
            let savedSummary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Every week")).firstMatch
            for _ in 0..<8 where !savedSummary.isHittable { app.swipeUp() }
            XCTAssertTrue(savedSummary.waitForExistence(timeout: 5))
            capture(app, "smart-add-recurrence-saved-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testSymbolUsesCaretAndNoDueDatePreview() {
        continueAfterFailure = false
        let app = launch("light")
        let input = openComposer(app)
        input.typeText("Plan suffix")
        for _ in 0..<7 { app.typeKey(.leftArrow, modifierFlags: []) }
        app.buttons["quick-add-symbol-!"].tap()
        XCTAssertEqual(input.value as? String, "Plan ! suffix")
        input.typeText("2")
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(input.value as? String, "Plan !2 suffix")
        for _ in 0..<6 { app.typeKey(.rightArrow, modifierFlags: []) }
        app.buttons["quick-add-symbol-^"].tap()
        input.typeText("none")
        app.typeKey(.tab, modifierFlags: [])
        let noDueChip = app.descendants(matching: .any)["quick-add-chip-no-due-date"]
        XCTAssertTrue(noDueChip.exists)
        XCTAssertEqual(noDueChip.label, "No due date")
        XCTAssertEqual(app.staticTexts["quick-add-title"].label, "Plan suffix")
        app.buttons["Cancel"].tap()
        app.buttons["New task"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue((input.value as? String)?.contains("^none") == true)
        app.buttons["quick-add-save"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testHardwareSelectionAndEscapeDoNotSave() {
        continueAfterFailure = false
        let app = launch("dark", directEscape: true)
        let input = openComposer(app)
        input.typeText("Hardware capture !")
        XCTAssertTrue(app.buttons["quick-add-suggestion-!1"].waitForExistence(timeout: 5))
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(input.value as? String, "Hardware capture !2 ")
        XCTAssertTrue(input.exists)
        app.buttons["quick-add-symbol-^"].tap()
        XCTAssertTrue(app.buttons["quick-add-suggestion-^today"].waitForExistence(timeout: 5))
        invokeRegisteredEscape(in: app, input: input)
        XCTAssertTrue(app.buttons["quick-add-suggestion-^today"].waitForNonExistence(timeout: 5), input.label)
        XCTAssertTrue(input.exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        input.typeText("tom")
        XCTAssertTrue(app.buttons["quick-add-suggestion-^tomorrow"].waitForExistence(timeout: 5))
        input.typeText("\n")
        XCTAssertTrue(input.exists)
        XCTAssertEqual(input.value as? String, "Hardware capture !2 ^tomorrow ")
        input.typeText("\n")
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Hardware capture"))
        XCTAssertTrue(saved.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(saved.count, 1)
        app.terminate()
    }

    @MainActor
    private func assertSuggestionLayout(
        _ app: XCUIApplication, input: XCUIElement, rows: XCUIElementQuery,
        list: XCUIElement, above bar: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        assertVisibleCaret(app, input: input, list: list, file: file, line: line)
        XCTAssertLessThanOrEqual(list.frame.maxY, bar.frame.minY, file: file, line: line)
        let firstRow = rows.element(boundBy: 0)
        XCTAssertTrue(firstRow.exists, file: file, line: line)
        let headerHeight = firstRow.frame.minY - list.frame.minY
        let inputBottom = max(input.frame.maxY, app.buttons["Clear draft"].frame.maxY) + 20
        let availableHeight = max(0, bar.frame.minY - 4 - inputBottom)
        let preferredHeight = headerHeight + firstRow.frame.height * 4
        XCTAssertEqual(list.frame.height, min(availableHeight, preferredHeight), accuracy: 1, file: file, line: line)
        let expectedRows = max(1, min(4, Int((availableHeight - headerHeight + 1) / max(1, firstRow.frame.height))))
        XCTAssertGreaterThanOrEqual(visibleCount(rows, in: list, above: bar), expectedRows,
                                    "The input stays visible; four rows fit only when space permits", file: file, line: line)
    }

    @MainActor
    private func assertVisibleCaret(
        _ app: XCUIApplication, input: XCUIElement, list: XCUIElement,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let keyboard = app.keyboards.firstMatch
        let keyboardIntroduction = app.buttons["Continue"]
        if keyboardIntroduction.exists { keyboardIntroduction.tap() }
        XCTAssertTrue(keyboard.exists, file: file, line: line)
        XCTAssertTrue(keyboard.keys["space"].isHittable, file: file, line: line)
        XCTAssertFalse(keyboardIntroduction.exists, file: file, line: line)
        XCTAssertTrue(input.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(input.frame.minY, app.navigationBars["New Task"].frame.maxY, file: file, line: line)
        XCTAssertLessThanOrEqual(input.frame.maxY, list.frame.minY, file: file, line: line)
        let geometry = input.label.split(separator: "|").dropFirst().compactMap { Double($0) }
        guard geometry.count == 4 else {
            XCTFail("Missing native caret geometry: \(input.label)", file: file, line: line)
            return
        }
        let caret = CGRect(x: geometry[0], y: geometry[1], width: geometry[2], height: geometry[3])
        XCTAssertGreaterThan(caret.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(caret.minX, input.frame.minX - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(caret.maxX, input.frame.maxX + 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(caret.minY, input.frame.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(caret.maxY, min(input.frame.maxY, keyboard.frame.minY) + 1, file: file, line: line)
    }

    @MainActor
    private func visibleCount(_ rows: XCUIElementQuery, in list: XCUIElement, above bar: XCUIElement) -> Int {
        rows.allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.minY >= list.frame.minY - 1
                && $0.frame.maxY <= min(list.frame.maxY, bar.frame.minY) + 1
        }.count
    }

    @MainActor
    private func invokeRegisteredEscape(in app: XCUIApplication, input: XCUIElement) {
        // The isolated simulator probe delivers Tab but no synthesized Escape at application entry.
        // Invoke the registered action directly; Mac keeps end-to-end Escape coverage.
        let trigger = app.buttons["quick-add-test-escape"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.tap()
        let invoked = NSPredicate(format: "label CONTAINS %@", "escape=1,")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: invoked, object: input)], timeout: 5), .completed)
        XCTAssertTrue(input.label.contains("focused=true,"))
        XCTAssertTrue(app.navigationBars["New Task"].exists)
        XCTAssertTrue(input.exists)
    }

    @MainActor
    private func launch(_ appearance: String, unsynced: Bool = false, directEscape: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiTab", "tasks", "-uiAppearance", appearance, "-uiCaptureGeometry"]
        if unsynced { app.launchArguments += ["-demoUnsynced", "YES"] }
        if directEscape { app.launchArguments.append("-uiDirectEscape") }
        app.launch()
        return app
    }

    @MainActor
    private func openComposer(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.buttons["New task"].waitForExistence(timeout: 15))
        app.buttons["New task"].tap()
        let input = app.textViews["quick-add-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText("x")
        let clear = app.buttons["Clear draft"]
        if !clear.waitForExistence(timeout: 2) {
            let keyboardIntroduction = app.buttons["Continue"]
            XCTAssertTrue(keyboardIntroduction.waitForExistence(timeout: 10))
            keyboardIntroduction.tap()
            input.typeText("x")
            XCTAssertTrue(clear.waitForExistence(timeout: 5))
        }
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
        XCTAssertEqual(input.value as? String, "x")
        clear.tap()
        XCTAssertTrue(app.keyboards.firstMatch.keys["space"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.keys["space"].isHittable)
        return input
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
