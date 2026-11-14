import XCTest

final class InboxTriageTests: XCTestCase {
    @MainActor
    func testCategorizedInboxDateChoicesAndUndo() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            add("Inbox date review #work-engineering", in: app, expectedToast: "Added to Inbox · Work Engineering")
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Inbox date review"))
            let row = rows.element
            reveal(row, in: app)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(row.value as? String, "Inbox")
            XCTAssertTrue(row.label.contains("Work Engineering"))
            XCTAssertTrue(row.label.contains("Date decision pending"))
            let id = String(row.identifier.dropFirst("tasks-row-".count))
            capture(app, "inbox-triage-\(appearance)")

            app.buttons["inbox-someday-\(id)"].tap()
            XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5))
            app.buttons["Undo"].tap()
            reveal(row, in: app)
            waitForValue("Inbox", on: row)
            XCTAssertTrue(app.buttons["inbox-someday-\(id)"].exists)

            app.buttons["inbox-set-due-\(id)"].tap()
            XCTAssertTrue(app.datePickers["inbox-due-date-picker"].waitForExistence(timeout: 5))
            capture(app, "inbox-triage-date-picker-\(appearance)")
            app.buttons["inbox-due-cancel"].tap()
            XCTAssertTrue(app.buttons["inbox-due-save"].waitForNonExistence(timeout: 5))
            XCTAssertEqual(row.value as? String, "Inbox")
            app.buttons["inbox-set-due-\(id)"].tap()
            app.buttons["inbox-due-save"].tap()
            XCTAssertTrue(app.buttons["inbox-due-save"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5))
            app.buttons["Undo"].tap()
            reveal(row, in: app)
            waitForValue("Inbox", on: row)

            row.tap()
            let someday = app.switches["task-someday"]
            XCTAssertTrue(someday.waitForExistence(timeout: 5))
            XCTAssertEqual(someday.value as? String, "0")
            XCTAssertTrue(app.staticTexts["task-date-decision-pending"].exists)
            setTaskEditorSwitch("task-someday", on: true, in: app)
            capture(app, "inbox-triage-editor-someday-\(appearance)")
            app.buttons["task-editor-cancel"].tap()
            XCTAssertTrue(someday.waitForNonExistence(timeout: 5))
            XCTAssertEqual(row.value as? String, "Inbox")
            row.tap()
            XCTAssertTrue(someday.waitForExistence(timeout: 5))
            XCTAssertEqual(someday.value as? String, "0")
            setTaskEditorSwitch("task-someday", on: true, in: app)
            app.buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
            reveal(row, in: app)
            waitForValue("Work Engineering", on: row)
            XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(row.label.contains("Someday"))
            assertNoSchedulingWarning(row)
            row.tap()
            XCTAssertTrue(app.switches["task-someday"].waitForExistence(timeout: 5))
            app.buttons["task-due-add"].tap()
            XCTAssertEqual(app.switches["task-someday"].value as? String, "0")
            XCTAssertTrue(app.datePickers["task-due-date"].exists)
            app.buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
            reveal(row, in: app)
            waitForValue("Work Engineering", on: row)
            XCTAssertEqual(rows.count, 1)
            app.terminate()
        }
    }

    @MainActor
    func testSomedayStillRequiresCategoryAndEditorCanResetDecision() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            add("Unfiled date decision", in: app)
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Unfiled date decision"))
            let row = rows.element
            reveal(row, in: app)
            let id = String(row.identifier.dropFirst("tasks-row-".count))
            app.buttons["inbox-someday-\(id)"].tap()
            XCTAssertTrue(app.buttons["inbox-someday-\(id)"].waitForNonExistence(timeout: 5))
            XCTAssertEqual(row.value as? String, "Inbox")
            XCTAssertTrue(row.label.contains("Someday"))
            row.tap()
            XCTAssertTrue(app.switches["task-someday"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.switches["task-someday"].value as? String, "1")
            app.buttons["task-category"].tap()
            app.buttons["Home"].tap()
            app.buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
            reveal(row, in: app)
            waitForValue("Home", on: row)
            XCTAssertEqual(rows.count, 1)
            row.tap()
            XCTAssertTrue(app.switches["task-someday"].waitForExistence(timeout: 5))
            setTaskEditorSwitch("task-someday", on: false, in: app)
            XCTAssertTrue(app.staticTexts["task-date-decision-pending"].exists)
            capture(app, "inbox-triage-reset-editor-\(appearance)")
            app.buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
            reveal(row, in: app)
            waitForValue("Inbox", on: row)
            XCTAssertTrue(row.label.contains("Home"))
            XCTAssertTrue(app.buttons["inbox-someday-\(id)"].exists)
            XCTAssertEqual(rows.count, 1)
            capture(app, "inbox-triage-reset-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testExplicitSomedayCaptureRequiresCategory() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            add("Smart filed no deadline #work-engineering ^none", in: app, expectedToast: "Added to Work Engineering")
            let filedRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Smart filed no deadline"))
            let filed = filedRows.element
            reveal(filed, in: app)
            waitForValue("Work Engineering", on: filed)
            XCTAssertEqual(filedRows.count, 1)
            XCTAssertTrue(filed.label.contains("Someday"))
            assertNoSchedulingWarning(filed)
            filed.tap()
            XCTAssertTrue(app.switches["task-someday"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.switches["task-someday"].value as? String, "1")
            XCTAssertTrue(app.buttons["task-due-add"].exists)
            XCTAssertFalse(app.staticTexts["task-date-decision-pending"].exists)
            app.buttons["task-editor-cancel"].tap()

            app.buttons["New task"].tap()
            let input = app.textViews["quick-add-input"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("Smart reviewed no deadline #work-engineering ^someday")
            app.buttons["Details"].tap()
            XCTAssertTrue(app.switches["task-someday"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.switches["task-someday"].value as? String, "1")
            app.buttons["Add"].tap()
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            let reviewedRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Smart reviewed no deadline"))
            reveal(reviewedRows.element, in: app)
            waitForValue("Work Engineering", on: reviewedRows.element)
            XCTAssertEqual(reviewedRows.count, 1)

            add("Smart unfiled no deadline ^none", in: app, expectedToast: "Added to Inbox")
            let unfiledRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Smart unfiled no deadline"))
            let unfiled = unfiledRows.element
            reveal(unfiled, in: app)
            waitForValue("Inbox", on: unfiled)
            XCTAssertTrue(unfiled.label.contains("Someday"))
            XCTAssertEqual(unfiledRows.count, 1)
            let id = String(unfiled.identifier.dropFirst("tasks-row-".count))
            XCTAssertFalse(app.buttons["inbox-someday-\(id)"].exists)
            capture(app, "inbox-triage-explicit-someday-\(appearance)")

            app.buttons["New task"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("Ambiguous no deadline #work ^none")
            XCTAssertFalse(app.buttons["quick-add-save"].isEnabled)
            let noDueDate = app.buttons["quick-add-suggestion-^none"]
            XCTAssertTrue(noDueDate.waitForExistence(timeout: 5))
            noDueDate.tap()
            XCTAssertEqual(input.value as? String, "Ambiguous no deadline #work ^none ")
            let engineering = app.buttons["quick-add-category-demo-eng"]
            XCTAssertTrue(engineering.waitForExistence(timeout: 5))
            XCTAssertTrue(engineering.isHittable)
            capture(app, "inbox-triage-resolve-category-\(appearance)")
            engineering.tap()
            app.buttons["quick-add-save"].tap()
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            let resolvedRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Ambiguous no deadline"))
            reveal(resolvedRows.element, in: app)
            waitForValue("Work Engineering", on: resolvedRows.element)
            XCTAssertEqual(resolvedRows.count, 1)
            add("Literal nodue #home", in: app)
            let literal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Literal nodue")).element
            reveal(literal, in: app)
            waitForValue("Inbox", on: literal)
            XCTAssertTrue(literal.label.contains("Date decision pending"))
            app.terminate()
        }
    }

    @MainActor
    func testRepeatingSomedaySurvivesUnrelatedEdits() {
        continueAfterFailure = false
        let app = launch("light")
        defer { app.terminate() }
        add("Retained repeat decision #home *weekly ^none", in: app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Retained repeat decision")).element
        reveal(row, in: app)
        waitForValue("Home", on: row)
        row.tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
        app.textFields["Title"].tap()
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.textFields["Title"].typeText(" renamed")
        XCTAssertEqual(app.textFields["Title"].value as? String, "Retained repeat decision renamed")
        app.buttons["Save"].tap()
        let renamed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Retained repeat decision renamed")).element
        reveal(renamed, in: app)
        waitForValue("Home", on: renamed)
        renamed.tap()
        XCTAssertTrue(app.switches["task-someday"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["task-someday"].value as? String, "1")
        XCTAssertTrue(app.buttons["task-due-add"].exists)
        XCTAssertFalse(app.staticTexts["task-date-decision-pending"].exists)
        app.buttons["task-editor-cancel"].tap()
        reveal(renamed, in: app)
        XCTAssertTrue(renamed.label.contains("Someday"))
        assertNoSchedulingWarning(renamed)
    }

    @MainActor
    func testSomedayToggleClearsDueAndPinButKeepsStart() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            add("Date decision transition #home ~today ^tomorrow", in: app)
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Date decision transition")).element
            reveal(row, in: app)
            row.tap()
            let someday = app.switches["task-someday"]
            XCTAssertTrue(someday.waitForExistence(timeout: 5))
            XCTAssertEqual(someday.value as? String, "0")
            XCTAssertTrue(app.datePickers["task-start-date"].exists)
            let start = app.datePickers["task-start-date"].value as? String
            setTaskEditorSwitch("task-pin", on: true, in: app)
            setTaskEditorSwitch("task-someday", on: true, in: app, upwards: true)
            XCTAssertEqual(someday.value as? String, "1")
            XCTAssertTrue(someday.label.contains("No due date"))
            XCTAssertTrue(app.buttons["task-due-add"].exists)
            XCTAssertEqual(app.datePickers["task-start-date"].value as? String, start)
            XCTAssertFalse(app.staticTexts["task-date-decision-pending"].exists)
            capture(app, "inbox-triage-someday-cleared-due-\(appearance)")
            revealTaskEditorControl(app.staticTexts["task-plan-someday"], in: app)
            XCTAssertFalse(app.buttons["task-why"].exists)
            revealTaskEditorControl(app.switches["task-pin"], in: app)
            XCTAssertEqual(app.switches["task-pin"].value as? String, "0")
            app.buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
            reveal(row, in: app)
            XCTAssertTrue(row.label.contains("Someday"))
            assertNoSchedulingWarning(row)
            row.tap()
            XCTAssertTrue(someday.waitForExistence(timeout: 5))
            XCTAssertEqual(someday.value as? String, "1")
            XCTAssertEqual(app.datePickers["task-start-date"].value as? String, start)
            setTaskEditorSwitch("task-someday", on: false, in: app)
            XCTAssertEqual(someday.value as? String, "0")
            XCTAssertFalse(app.staticTexts["task-date-decision-pending"].exists)
            app.buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
            reveal(row, in: app)
            waitForValue("Home", on: row)
            app.terminate()
        }
    }

    @MainActor
    func testActualDateActionsLeaveSomeday() {
        continueAfterFailure = false
        let app = launch("light")
        defer { app.terminate() }
        add("Date action review #home someday", in: app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Date action review")).element
        reveal(row, in: app)
        row.tap()
        let someday = app.switches["task-someday"]
        XCTAssertTrue(someday.waitForExistence(timeout: 5))
        XCTAssertEqual(someday.value as? String, "1")
        app.buttons["task-start-add"].tap()
        XCTAssertEqual(someday.value as? String, "0")
        setTaskEditorSwitch("task-someday", on: true, in: app)
        app.buttons["task-due-add"].tap()
        XCTAssertEqual(someday.value as? String, "0")
        setTaskEditorSwitch("task-someday", on: true, in: app)
        setTaskEditorSwitch("task-pin", on: true, in: app)
        revealTaskEditorControl(app.switches["task-someday"], in: app, upwards: true)
        XCTAssertEqual(someday.value as? String, "0")
        XCTAssertFalse(app.staticTexts["task-date-decision-pending"].exists)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
        reveal(row, in: app)
        waitForValue("Home", on: row)
        XCTAssertFalse(row.label.contains("Someday"))
    }

    @MainActor
    func testSomedaySuppressesStalePlacementAndUnscheduledWarning() {
        continueAfterFailure = false
        let app = launch("light")
        defer { app.terminate() }
        let row = app.buttons["tasks-row-demo-task-roadmap"]
        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.switches["task-someday"].waitForExistence(timeout: 5))
        setTaskEditorSwitch("task-someday", on: true, in: app)
        revealTaskEditorControl(app.staticTexts["task-plan-someday"], in: app)
        XCTAssertFalse(app.buttons["task-why"].exists)
        capture(app, "inbox-triage-someday-suppresses-placement")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
        reveal(row, in: app)
        XCTAssertTrue(row.label.contains("Someday"))
        assertNoSchedulingWarning(row)

        let unplaced = app.buttons["tasks-row-demo-task-vpn"]
        reveal(unplaced, in: app)
        unplaced.tap()
        XCTAssertTrue(app.switches["task-someday"].waitForExistence(timeout: 5))
        setTaskEditorSwitch("task-someday", on: true, in: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
        reveal(unplaced, in: app)
        XCTAssertTrue(unplaced.label.contains("Someday"))
        assertNoSchedulingWarning(unplaced)
        XCTAssertFalse(unplaced.label.contains("unplaced"))
    }

    @MainActor
    private func assertNoSchedulingWarning(_ row: XCUIElement) {
        for text in ["Unscheduled", "Late", "Overdue", "unplaced", "Date decision pending"] {
            XCTAssertFalse(row.label.contains(text), "Someday must not show \(text)")
        }
    }

    @MainActor
    private func launch(_ appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiTab", "tasks", "-uiAppearance", appearance,
                               "-uiTraceInbox", "YES"]
        app.launch()
        let options = app.buttons["tasks-view-options"]
        XCTAssertTrue(options.waitForExistence(timeout: 15))
        options.tap()
        let category = app.buttons["Category"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.tap()
        XCTAssertTrue(category.waitForNonExistence(timeout: 5))
        XCTAssertEqual(options.value as? String, "Group by Category")
        return app
    }

    @MainActor
    private func add(_ text: String, in app: XCUIApplication, expectedToast: String? = nil) {
        XCTAssertTrue(app.buttons["New task"].waitForExistence(timeout: 15))
        app.buttons["New task"].tap()
        let input = app.textViews["quick-add-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
        input.typeText(text)
        app.buttons["quick-add-save"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        if let expectedToast { XCTAssertTrue(app.staticTexts[expectedToast].waitForExistence(timeout: 5)) }
    }

    @MainActor
    private func reveal(_ row: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews["tasks-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let top = max(list.frame.minY, app.navigationBars.firstMatch.frame.maxY + 8)
        let bottom = min(list.frame.maxY, app.tabBars.firstMatch.frame.minY - 60)
        let middle = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: list.frame.midX, dy: (top + bottom) / 2))
        var identifier: String?
        if !row.exists {
            for _ in 0..<6 {
                middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 160)),
                             withVelocity: .slow, thenHoldForDuration: 0.3)
            }
        }
        for _ in 0..<12 {
            let current = identifier.map { app.buttons[$0] } ?? row
            var travel: CGFloat = -160
            if current.exists {
                identifier = current.identifier
                let frame = current.frame
                if !frame.isEmpty, [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) {
                    if frame.minY >= top, frame.maxY <= bottom, current.isHittable { break }
                    let distance = frame.minY < top ? top - frame.minY : bottom - frame.maxY
                    travel = distance > 0 ? min(160, max(32, distance)) : max(-160, min(-32, distance))
                }
            }
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: travel)),
                         withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        let current = identifier.map { app.buttons[$0] } ?? row
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        let frame = current.frame
        guard !frame.isEmpty, [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) else {
            XCTFail("The task row must have a finite, nonempty frame")
            return
        }
        XCTAssertGreaterThanOrEqual(frame.minY, top)
        XCTAssertLessThanOrEqual(frame.maxY, bottom)
        XCTAssertTrue(current.isHittable)
    }

    @MainActor
    private func waitForValue(_ value: String, on row: XCUIElement) {
        let predicate = NSPredicate(format: "value == %@", value)
        expectation(for: predicate, evaluatedWith: row)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
