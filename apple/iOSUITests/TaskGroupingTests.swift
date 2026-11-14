import XCTest

final class TaskGroupingTests: XCTestCase {
    @MainActor
    func testDueDateSectionsCategoryChipsAndRememberedGroupingInBothAppearances() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            selectGrouping("Due date", in: app)
            scrollToTop(app)
            capture(app, "task-grouping-due-\(appearance)")

            let due = scanList(app, showsCategories: true)
            XCTAssertEqual(due.sections, [
                "inbox", "overdue", "today", "tomorrow", "this-week", "next-week", "later", "someday",
            ])
            XCTAssertEqual(due.rows, [
                "group-categorized-inbox", "group-inbox", "group-overdue", "group-today-early", "group-today-hard", "group-today-soft",
                "group-pinned", "group-tomorrow", "group-this-week", "group-next-week", "group-later", "group-no-due", "group-someday",
            ])
            capture(app, "task-grouping-someday-\(appearance)")
            XCTAssertFalse(app.buttons["tasks-row-group-completed"].exists)
            XCTAssertTrue(app.buttons["tasks-projects-link"].isHittable)

            selectGrouping("Category", in: app)
            scrollToTop(app)
            capture(app, "task-grouping-category-\(appearance)")
            let source = app.buttons["task-source-open-group-today-soft"]
            reveal(source, in: app)
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertTrue(source.isHittable)
            XCTAssertEqual(app.buttons.matching(identifier: "task-source-open-group-today-soft").count, 1)
            XCTAssertFalse(element("task-source-mark-group-today-soft", in: app).exists)
            XCTAssertFalse(element("task-context-group-today-soft", in: app).exists)
            source.tap()
            let opened = app.staticTexts["source-opened-url"]
            XCTAssertTrue(opened.waitForExistence(timeout: 5))
            XCTAssertEqual(opened.label, "https://example.com/grouping")
            XCTAssertFalse(app.navigationBars["Edit Task"].exists)
            scrollToTop(app)
            let category = scanList(app, showsCategories: false)
            XCTAssertEqual(category.sections, [
                "inbox", "category:demo-eng", "category:demo-infosec", "category:demo-home", "category:demo-finance",
            ])
            XCTAssertEqual(category.rows, [
                "group-categorized-inbox", "group-inbox", "group-today-soft", "group-tomorrow", "group-this-week", "group-no-due", "group-someday",
                "group-today-hard", "group-pinned", "group-later", "group-overdue", "group-today-early", "group-next-week",
            ])
            app.terminate()

            app.launch()
            XCTAssertTrue(app.buttons["tasks-view-options"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.buttons["tasks-view-options"].value as? String, "Group by Category")
            XCTAssertTrue(element("tasks-section-category:demo-eng", in: app).waitForExistence(timeout: 5))
            selectGrouping("Due date", in: app)
            app.terminate()

            app.launch()
            XCTAssertTrue(app.buttons["tasks-view-options"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.buttons["tasks-view-options"].value as? String, "Group by Due date")
            XCTAssertTrue(element("tasks-section-overdue", in: app).waitForExistence(timeout: 5))
            capture(app, "task-grouping-restored-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testInboxTriageUndoAndFinalSomedayIntentPreserveSource() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            selectGrouping("Due date", in: app)
            scrollToTop(app)
            let row = app.buttons["tasks-row-group-categorized-inbox"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertEqual(row.value as? String, "Inbox")
            XCTAssertTrue(row.label.contains("Category: Work Engineering"))
            let source = app.buttons["task-source-open-group-categorized-inbox"]
            XCTAssertTrue(source.exists)
            capture(app, "task-grouping-categorized-inbox-\(appearance)")

            app.buttons["inbox-someday-group-categorized-inbox"].tap()
            let undo = app.buttons["Undo"]
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            undo.tap()
            XCTAssertTrue(app.buttons["inbox-set-due-group-categorized-inbox"].waitForExistence(timeout: 5))
            XCTAssertEqual(row.value as? String, "Inbox")
            XCTAssertTrue(source.exists)
            app.buttons["inbox-set-due-group-categorized-inbox"].tap()
            XCTAssertTrue(app.buttons["inbox-due-save"].waitForExistence(timeout: 5))
            app.buttons["inbox-due-save"].tap()
            XCTAssertTrue(app.buttons["inbox-due-save"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            undo.tap()
            XCTAssertTrue(app.buttons["inbox-someday-group-categorized-inbox"].waitForExistence(timeout: 5))
            XCTAssertEqual(row.value as? String, "Inbox")
            XCTAssertTrue(source.exists)

            row.tap()
            let someday = app.switches["task-someday"]
            XCTAssertTrue(someday.waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["task-source-url"].value as? String, "https://example.com/inbox")
            app.buttons["task-start-add"].tap()
            let startControl = app.datePickers["task-start-date"].buttons.firstMatch
            XCTAssertTrue(startControl.waitForExistence(timeout: 5))
            let start = try XCTUnwrap(startControl.value as? String)
            setTaskEditorSwitch("task-someday", on: true, in: app)
            XCTAssertEqual(someday.value as? String, "1")
            setTaskEditorSwitch("task-someday", on: false, in: app)
            XCTAssertEqual(someday.value as? String, "0")
            setTaskEditorSwitch("task-someday", on: true, in: app)
            XCTAssertEqual(someday.value as? String, "1")
            app.buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
            reveal(row, in: app)
            XCTAssertEqual(row.value as? String, "Someday")
            XCTAssertTrue(row.label.contains("Someday"))
            XCTAssertTrue(source.exists)
            capture(app, "task-grouping-final-someday-source-\(appearance)")

            row.tap()
            XCTAssertTrue(someday.waitForExistence(timeout: 5))
            XCTAssertEqual(someday.value as? String, "1")
            XCTAssertEqual(try XCTUnwrap(startControl.value as? String), start)
            app.buttons["task-start-options"].tap()
            app.buttons["Add a time"].tap()
            XCTAssertEqual(someday.value as? String, "0", "Adding a time must explicitly leave Someday")
            setTaskEditorSwitch("task-someday", on: true, in: app)
            XCTAssertEqual(someday.value as? String, "1")
            app.buttons["task-start-options"].tap()
            app.buttons["Remove the time"].tap()
            XCTAssertEqual(someday.value as? String, "0", "A same-date action must explicitly leave Someday")
            XCTAssertEqual(try XCTUnwrap(startControl.value as? String), start)
            XCTAssertEqual(app.textFields["task-source-url"].value as? String, "https://example.com/inbox")
            capture(app, "task-grouping-same-date-leaves-someday-\(appearance)")
            app.buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
            reveal(row, in: app)
            XCTAssertNotEqual(row.value as? String, "Someday")
            XCTAssertTrue(row.label.contains("Start "))
            XCTAssertTrue(source.exists)
            source.tap()
            XCTAssertEqual(app.staticTexts["source-opened-url"].label, "https://example.com/inbox")
            XCTAssertFalse(app.navigationBars["Edit Task"].exists)
            app.terminate()
        }
    }

    @MainActor
    private func reveal(_ row: XCUIElement, in app: XCUIApplication) {
        scrollToTop(app)
        for _ in 0..<20 where !row.isHittable {
            app.collectionViews["tasks-list"].swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isHittable)
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-demoData", "YES", "-uiTaskGroupingDemo", "YES", "-demoNow", "2026-11-18T12:00:00Z",
            "-uiRecordSourceOpens", "YES",
            "-uiTab", "tasks", "-uiAppearance", appearance,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["tasks-row-group-inbox"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func selectGrouping(_ title: String, in app: XCUIApplication) {
        let menu = app.buttons["tasks-view-options"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        XCTAssertTrue(option.waitForNonExistence(timeout: 5))
        XCTAssertEqual(menu.value as? String, "Group by \(title)")
    }

    @MainActor
    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<15 where !app.buttons["Quick add"].isHittable {
            app.collectionViews["tasks-list"].swipeDown()
        }
        XCTAssertTrue(app.buttons["Quick add"].isHittable)
    }

    @MainActor
    private func scanList(_ app: XCUIApplication, showsCategories: Bool) -> (sections: [String], rows: [String]) {
        var sections: [String] = []
        var rows: [String] = []
        let categories = [
            "group-categorized-inbox": "Work Engineering",
            "group-inbox": "Inbox",
            "group-overdue": "Personal Finance",
            "group-today-early": "Personal Finance",
            "group-today-hard": "Work Infosec",
            "group-today-soft": "Work Engineering",
            "group-tomorrow": "Work Engineering",
            "group-this-week": "Work Engineering",
            "group-next-week": "Personal Finance",
            "group-later": "Work Infosec",
            "group-no-due": "Work Engineering",
            "group-pinned": "Work Infosec",
            "group-someday": "Work Engineering",
        ]
        let list = app.collectionViews["tasks-list"]
        XCTAssertTrue(element("tasks-list", in: app).exists)
        for _ in 0..<20 {
            let visible = CGRect(
                x: list.frame.minX, y: app.navigationBars.firstMatch.frame.maxY,
                width: list.frame.width,
                height: app.tabBars.firstMatch.frame.minY - app.navigationBars.firstMatch.frame.maxY)
            let headers = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "tasks-section-"))
                .allElementsBoundByIndex.filter { $0.frame.intersects(visible) }
                .sorted { $0.frame.minY < $1.frame.minY }
            for header in headers {
                let id = String(header.identifier.dropFirst("tasks-section-".count))
                if !sections.contains(id) { sections.append(id) }
            }
            let buttons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tasks-row-"))
                .allElementsBoundByIndex.filter { $0.frame.intersects(visible) }
                .sorted { $0.frame.minY < $1.frame.minY }
            for button in buttons {
                let id = String(button.identifier.dropFirst("tasks-row-".count))
                if !rows.contains(id) {
                    rows.append(id)
                    if id == "group-categorized-inbox" || (showsCategories && id != "group-inbox") {
                        XCTAssertTrue(button.label.contains("Category: \(categories[id] ?? "Unexpected task")"), button.label)
                    } else {
                        XCTAssertFalse(button.label.contains("Category:"), button.label)
                    }
                    XCTAssertLessThanOrEqual(button.frame.height, 104, "Metadata must not add a line: \(id)")
                    if id == "group-today-soft" {
                        XCTAssertFalse(element("task-source-mark-group-today-soft", in: app).exists)
                        XCTAssertFalse(element("task-context-group-today-soft", in: app).exists)
                        let dates = button.descendants(matching: .any).matching(identifier: "task-list-date-\(id)")
                        XCTAssertEqual(dates.count, 1, "A date caption must expose one native accessibility element")
                        let due = dates.element
                        XCTAssertTrue(due.exists, "The due phrase must remain visible, not collapse to an icon")
                        XCTAssertTrue(NSPredicate(format: "SELF MATCHES %@", "By Today .*[0-9]{1,2}:[0-9]{2}.*").evaluate(with: due.label))
                        XCTAssertGreaterThan(due.frame.width, 60)
                        XCTAssertLessThanOrEqual(due.frame.height, 18)
                    }
                    if id == "group-pinned" || id == "group-no-due" {
                        let dates = button.descendants(matching: .any).matching(identifier: "task-list-date-\(id)")
                        XCTAssertEqual(dates.count, 1, "A date caption must expose one native accessibility element")
                        let date = dates.element
                        XCTAssertTrue(date.exists)
                        XCTAssertTrue(date.label.hasPrefix(id == "group-pinned" ? "Pinned " : "Start "), date.label)
                        XCTAssertFalse(date.label.hasPrefix("By "))
                        XCTAssertGreaterThan(date.frame.width, 60)
                        XCTAssertLessThanOrEqual(date.frame.height, 18)
                        if showsCategories { XCTAssertEqual(button.value as? String, id == "group-pinned" ? "Tomorrow" : "Later") }
                        capture(app, "task-grouping-\(id)-\(showsCategories ? "date" : "category")")
                    }
                    if id == "group-someday" {
                        XCTAssertTrue(button.label.contains("Someday"))
                        XCTAssertFalse(button.descendants(matching: .any)["task-list-date-\(id)"].exists)
                        if showsCategories { XCTAssertEqual(button.value as? String, "Someday") }
                    }
                }
            }
            if app.buttons["tasks-projects-link"].isHittable { break }
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        return (sections, rows)
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).element
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
