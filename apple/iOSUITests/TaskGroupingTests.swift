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
                "inbox", "overdue", "today", "tomorrow", "this-week", "next-week", "later", "no-due-date",
            ])
            XCTAssertEqual(due.rows, [
                "group-inbox", "group-overdue", "group-today-early", "group-today-hard", "group-today-soft",
                "group-tomorrow", "group-this-week", "group-next-week", "group-later", "group-no-due",
            ])
            XCTAssertFalse(app.buttons["tasks-row-group-completed"].exists)
            XCTAssertTrue(app.buttons["tasks-projects-link"].isHittable)

            selectGrouping("Category", in: app)
            scrollToTop(app)
            capture(app, "task-grouping-category-\(appearance)")
            let source = app.buttons["task-source-open-group-today-soft"]
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertTrue(source.isHittable)
            source.tap()
            let opened = app.staticTexts["source-opened-url"]
            XCTAssertTrue(opened.waitForExistence(timeout: 5))
            XCTAssertEqual(opened.label, "https://example.com/grouping")
            XCTAssertFalse(app.navigationBars["Edit Task"].exists)
            let category = scanList(app, showsCategories: false)
            XCTAssertEqual(category.sections, [
                "inbox", "category:demo-eng", "category:demo-infosec", "category:demo-home", "category:demo-finance",
            ])
            XCTAssertEqual(category.rows, [
                "group-inbox", "group-today-soft", "group-tomorrow", "group-this-week", "group-no-due",
                "group-today-hard", "group-later", "group-overdue", "group-today-early", "group-next-week",
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
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(app.buttons["Quick add"].isHittable)
    }

    @MainActor
    private func scanList(_ app: XCUIApplication, showsCategories: Bool) -> (sections: [String], rows: [String]) {
        var sections: [String] = []
        var rows: [String] = []
        let categories = [
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
        ]
        let list = app.collectionViews.firstMatch
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
                    if showsCategories, id != "group-inbox" {
                        XCTAssertTrue(button.label.contains("Category: \(categories[id] ?? "Unexpected task")"), button.label)
                    } else {
                        XCTAssertFalse(button.label.contains("Category:"), button.label)
                    }
                    XCTAssertLessThanOrEqual(button.frame.height, 104, "Metadata must not add a line: \(id)")
                    if id == "group-today-soft" {
                        let due = button.staticTexts
                            .matching(NSPredicate(format: "label MATCHES %@", "By Today .*[0-9]{1,2}:[0-9]{2}.*")).firstMatch
                        XCTAssertTrue(due.exists, "The due phrase must remain visible, not collapse to an icon")
                        XCTAssertGreaterThan(due.frame.width, 60)
                        XCTAssertLessThanOrEqual(due.frame.height, 18)
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
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
