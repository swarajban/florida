import XCTest

final class InboxTriageTests: XCTestCase {
    @MainActor
    func testInboxDateDecisionsInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            defer { app.terminate() }
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 10))

            app.typeKey("?", modifierFlags: [])
            let byDate = app.descendants(matching: .any)["help-command-Set due date…"]
            XCTAssertTrue(byDate.waitForExistence(timeout: 5))
            waitForValue("b", of: byDate)
            waitForValue("i", of: app.descendants(matching: .any)["help-command-Someday"])
            waitForValue("y", of: app.descendants(matching: .any)["help-command-Why here?"])
            waitForValue("s", of: app.descendants(matching: .any)["help-command-Snooze"])
            waitForValue("m", of: app.descendants(matching: .any)["help-command-Move to…"])
            waitForValue("g b", of: app.descendants(matching: .any)["help-command-Brief"])
            app.typeKey(.escape, modifierFlags: [])

            quickAdd("Triage categorized #work-infosec // local fixture", in: app)
            let categorized = row("Triage categorized", in: app)
            XCTAssertTrue(categorized.waitForExistence(timeout: 5))
            waitForTriage("Inbox", of: categorized)
            let id = String(categorized.identifier.dropFirst("task-row-".count))
            XCTAssertEqual(rows("Triage categorized", in: app).count, 1)
            let categoryChip = categorized.staticTexts["task-category-chip-demo-infosec"]
            XCTAssertTrue(categoryChip.exists)
            XCTAssertEqual(categoryChip.value as? String, "Category: Work Infosec")

            app.typeKey("i", modifierFlags: [])
            waitForTriage("Categorized", of: categorized)
            assertSomeday(id: id, in: app)
            XCTAssertEqual(rows("Triage categorized", in: app).count, 1)
            XCTAssertFalse(app.buttons["task-triage-date-\(id)"].exists)
            app.typeKey("z", modifierFlags: [])
            waitForTriage("Inbox", of: categorized)
            XCTAssertNotEqual(app.staticTexts["task-schedule-label-\(id)"].value as? String, "Someday")

            app.typeKey("b", modifierFlags: [])
            let date = app.textFields["inbox-due-\(id)-search"]
            XCTAssertTrue(date.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["task-triage-date-\(id)"].exists)
            capture(window, "inbox-triage-\(appearance)")
            date.typeText("tomorrow")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(date.waitForNonExistence(timeout: 5))
            waitForTriage("Categorized", of: categorized)
            app.typeKey("z", modifierFlags: [])
            waitForTriage("Inbox", of: categorized)

            runPalette("Set due date", in: app)
            XCTAssertTrue(date.waitForExistence(timeout: 5))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(date.waitForNonExistence(timeout: 5))
            waitForTriage("Inbox", of: categorized)
            runPalette("Someday", in: app)
            waitForTriage("Categorized", of: categorized)
            assertSomeday(id: id, in: app)
            app.typeKey("y", modifierFlags: [])
            let explanation = app.staticTexts["explanation-text"]
            XCTAssertTrue(explanation.waitForExistence(timeout: 5))
            XCTAssertEqual(explanation.value as? String, "Someday")
            XCTAssertFalse(app.staticTexts["explanation-error"].exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(explanation.waitForNonExistence(timeout: 5))

            categorized.click()
            let noDue = app.checkBoxes["task-someday"]
            XCTAssertTrue(noDue.waitForExistence(timeout: 5))
            XCTAssertEqual((noDue.value as? NSNumber)?.intValue, 1)
            XCTAssertFalse(app.staticTexts["task-date-triage-warning"].exists)
            let title = app.textFields["task-title"]
            XCTAssertTrue(title.exists)
            title.click()
            title.typeKey("a", modifierFlags: .command)
            title.typeText("Triage edited")
            app.buttons["Save"].click()
            XCTAssertTrue(noDue.waitForNonExistence(timeout: 5))
            let edited = row("Triage edited", in: app)
            waitForTriage("Categorized", of: edited)
            edited.click()
            XCTAssertTrue(noDue.waitForExistence(timeout: 5))
            XCTAssertEqual((noDue.value as? NSNumber)?.intValue, 1)
            app.buttons["task-due"].click()
            let editorDate = app.textFields["task-due-search"]
            XCTAssertTrue(editorDate.waitForExistence(timeout: 5))
            editorDate.typeText("tomorrow")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(editorDate.waitForNonExistence(timeout: 5))
            XCTAssertEqual((noDue.value as? NSNumber)?.intValue, 0)
            app.buttons["Save"].click()
            XCTAssertTrue(noDue.waitForNonExistence(timeout: 5))
            app.typeKey("z", modifierFlags: [])
            edited.click()
            XCTAssertTrue(noDue.waitForExistence(timeout: 5))
            XCTAssertEqual((noDue.value as? NSNumber)?.intValue, 1)
            noDue.click()
            app.buttons["Save"].click()
            XCTAssertTrue(noDue.waitForNonExistence(timeout: 5))
            waitForTriage("Inbox", of: edited)
            app.typeKey("z", modifierFlags: [])
            waitForTriage("Categorized", of: edited)

            quickAdd("Triage uncategorized // local fixture", in: app)
            let uncategorized = row("Triage uncategorized", in: app)
            XCTAssertTrue(uncategorized.waitForExistence(timeout: 5))
            waitForTriage("Inbox", of: uncategorized)
            app.typeKey("i", modifierFlags: [])
            waitForTriage("Inbox", of: uncategorized)
            app.typeKey("m", modifierFlags: [])
            let move = app.textFields["palette-input"]
            XCTAssertTrue(move.waitForExistence(timeout: 5))
            move.typeText("Work Infosec")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(move.waitForNonExistence(timeout: 5))
            waitForTriage("Categorized", of: uncategorized)
            app.typeKey("z", modifierFlags: [])
            waitForTriage("Inbox", of: uncategorized)
        }
    }

    @MainActor
    func testClearingGeneratedDateResetsDormantNoDateDecision() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiAppearance", "light"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
        quickAdd("Retained repeat decision #home ~today *weekly ^none // fixture", in: app)
        let task = row("Retained repeat decision", in: app)
        waitForTriage("Categorized", of: task)
        task.click()
        let title = app.textFields["task-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeKey("a", modifierFlags: .command)
        title.typeText("Retained repeat renamed")
        app.buttons["Save"].click()
        let renamed = row("Retained repeat renamed", in: app)
        waitForTriage("Categorized", of: renamed)
        renamed.click()
        XCTAssertTrue(app.buttons["task-due"].waitForExistence(timeout: 5))
        XCTAssertEqual((app.checkBoxes["task-someday"].value as? NSNumber)?.intValue, 1)
        chooseEditorDate("task-due", "tomorrow", in: app)
        XCTAssertEqual((app.checkBoxes["task-someday"].value as? NSNumber)?.intValue, 0)
        app.buttons["task-due"].click()
        let date = app.textFields["task-due-search"]
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        date.typeText("none")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(date.waitForNonExistence(timeout: 5))
        waitForValue("No date", of: app.buttons["task-due"])
        XCTAssertEqual((app.checkBoxes["task-someday"].value as? NSNumber)?.intValue, 0)
        XCTAssertFalse(app.staticTexts["task-date-triage-warning"].exists)
        app.buttons["Save"].click()
        XCTAssertTrue(app.checkBoxes["task-someday"].waitForNonExistence(timeout: 5))
        waitForTriage("Categorized", of: renamed)
        renamed.click()
        XCTAssertTrue(app.buttons["task-start"].waitForExistence(timeout: 5))
        chooseEditorDate("task-start", "none", in: app)
        XCTAssertEqual((app.checkBoxes["task-someday"].value as? NSNumber)?.intValue, 0)
        app.buttons["Save"].click()
        XCTAssertTrue(app.checkBoxes["task-someday"].waitForNonExistence(timeout: 5))
        waitForTriage("Inbox", of: renamed)
        XCTAssertEqual(rows("Retained repeat renamed", in: app).count, 1)
    }

    @MainActor
    func testSomedayEditorTransitionsAndSchedulingActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiAppearance", "light"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))

        quickAdd("Deferred transitions #home ~tomorrow // fixture", in: app)
        let task = row("Deferred transitions", in: app)
        waitForTriage("Categorized", of: task)
        let id = String(task.identifier.dropFirst("task-row-".count))
        XCTAssertFalse(app.buttons["task-triage-date-\(id)"].exists)
        task.click()
        let someday = app.checkBoxes["task-someday"]
        XCTAssertTrue(someday.waitForExistence(timeout: 5))
        XCTAssertEqual(someday.label, "Someday")
        XCTAssertTrue(app.staticTexts["No due date"].exists)
        XCTAssertFalse(app.staticTexts["task-date-triage-warning"].exists)
        let start = app.buttons["task-start"].value as? String
        XCTAssertNotEqual(start, "No date")
        someday.click()
        XCTAssertEqual((someday.value as? NSNumber)?.intValue, 1)
        XCTAssertEqual(app.buttons["task-start"].value as? String, start)
        someday.click()
        XCTAssertEqual((someday.value as? NSNumber)?.intValue, 0)
        XCTAssertFalse(app.staticTexts["task-date-triage-warning"].exists)
        someday.click()
        app.buttons["Save"].click()
        XCTAssertTrue(someday.waitForNonExistence(timeout: 5))
        assertSomeday(id: id, in: app)

        task.click()
        XCTAssertTrue(someday.waitForExistence(timeout: 5))
        chooseEditorDate("task-start", "tomorrow", in: app)
        XCTAssertEqual((someday.value as? NSNumber)?.intValue, 0)
        app.buttons["Save"].click()
        XCTAssertTrue(someday.waitForNonExistence(timeout: 5))
        app.typeKey("z", modifierFlags: [])
        assertSomeday(id: id, in: app)

        task.click()
        XCTAssertTrue(someday.waitForExistence(timeout: 5))
        chooseEditorDate("task-due", "none", in: app)
        chooseEditorDate("task-start", "none", in: app)
        chooseEditorDate("task-pinned-start", "none", in: app)
        revealEditorControl(someday, in: app)
        XCTAssertEqual((someday.value as? NSNumber)?.intValue, 0)
        XCTAssertTrue(app.staticTexts["task-date-triage-warning"].exists)
        app.buttons["Save"].click()
        XCTAssertTrue(someday.waitForNonExistence(timeout: 5))
        waitForTriage("Inbox", of: task)
        app.typeKey("i", modifierFlags: [])
        assertSomeday(id: id, in: app)

        task.click()
        XCTAssertTrue(someday.waitForExistence(timeout: 5))
        chooseEditorDate("task-pinned-start", "tomorrow 3pm", in: app)
        revealEditorControl(someday, in: app)
        XCTAssertEqual((someday.value as? NSNumber)?.intValue, 0)
        XCTAssertFalse(app.staticTexts["task-date-triage-warning"].exists)
        app.buttons["Save"].click()
        XCTAssertTrue(someday.waitForNonExistence(timeout: 5))
        waitForTriage("Categorized", of: task)
        task.click()
        XCTAssertTrue(someday.waitForExistence(timeout: 5))
        chooseEditorDate("task-pinned-start", "none", in: app)
        revealEditorControl(someday, in: app)
        XCTAssertEqual((someday.value as? NSNumber)?.intValue, 0)
        XCTAssertTrue(app.staticTexts["task-date-triage-warning"].exists)
        app.buttons["Save"].click()
        XCTAssertTrue(someday.waitForNonExistence(timeout: 5))
        waitForTriage("Inbox", of: task)
        app.typeKey("z", modifierFlags: [])
        waitForTriage("Categorized", of: task)
        app.typeKey("i", modifierFlags: [])
        assertSomeday(id: id, in: app)

        task.click()
        XCTAssertTrue(someday.waitForExistence(timeout: 5))
        chooseEditorDate("task-pinned-start", "tomorrow 3pm", in: app)
        chooseEditorDate("task-due", "tomorrow", in: app)
        revealEditorControl(someday, in: app)
        someday.click()
        waitForValue("No date", of: app.buttons["task-due"])
        revealEditorControl(app.buttons["task-pinned-start"], in: app)
        waitForValue("No date", of: app.buttons["task-pinned-start"])
        app.buttons["Save"].click()
        XCTAssertTrue(someday.waitForNonExistence(timeout: 5))
        assertSomeday(id: id, in: app)

        app.typeKey("s", modifierFlags: [])
        wait(for: [expectation(for: NSPredicate(format: "value != %@", "Someday"),
                               evaluatedWith: app.staticTexts["task-schedule-label-\(id)"])], timeout: 5)
        waitForTriage("Categorized", of: task)
        app.typeKey("z", modifierFlags: [])
        assertSomeday(id: id, in: app)
        app.typeKey("n", modifierFlags: [])
        wait(for: [expectation(for: NSPredicate(format: "value != %@", "Someday"),
                               evaluatedWith: app.staticTexts["task-schedule-label-\(id)"])], timeout: 5)
        app.typeKey("z", modifierFlags: [])
        assertSomeday(id: id, in: app)
    }

    @MainActor
    func testSomedayQuickAddAliases() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiAppearance", "light"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
        for (index, token) in ["^someday", "someday", "^none"].enumerated() {
            let title = "Deferred alias \(index)"
            quickAdd("\(title) #home \(token) // fixture", in: app)
            let task = row(title, in: app)
            waitForTriage("Categorized", of: task)
            assertSomeday(id: String(task.identifier.dropFirst("task-row-".count)), in: app)
        }
    }

    @MainActor
    private func assertSomeday(id: String, in app: XCUIApplication) {
        let state = app.staticTexts["task-schedule-label-\(id)"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "value == %@", "Someday"), evaluatedWith: state)], timeout: 5)
        XCTAssertFalse(app.staticTexts["task-problem-\(id)"].exists)
    }

    @MainActor
    private func chooseEditorDate(_ identifier: String, _ date: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        revealEditorControl(button, in: app)
        button.click()
        let search = app.textFields["\(identifier)-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText(date)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func revealEditorControl(_ control: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !control.isHittable {
            app.sheets.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180)
        }
        for _ in 0..<6 where !control.isHittable {
            app.sheets.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 180)
        }
        XCTAssertTrue(control.isHittable)
    }

    @MainActor
    private func quickAdd(_ text: String, in app: XCUIApplication) {
        app.typeKey("c", modifierFlags: [])
        let input = app.textFields["palette-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText(text)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func runPalette(_ command: String, in app: XCUIApplication) {
        app.typeKey("k", modifierFlags: .command)
        let input = app.textFields["palette-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText(command)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func rows(_ title: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "task-row-", title))
    }

    @MainActor
    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        rows(title, in: app).firstMatch
    }

    @MainActor
    private func waitForTriage(_ state: String, of row: XCUIElement) {
        wait(for: [expectation(for: NSPredicate(format: "label ENDSWITH %@", ", \(state)"), evaluatedWith: row)], timeout: 5)
        XCTAssertTrue(row.isHittable, "The selected task must remain visible after date triage changes its section")
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement) {
        wait(for: [expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)], timeout: 5)
    }

    @MainActor
    private func capture(_ window: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
