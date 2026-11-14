import XCTest

final class TaskGroupingTests: XCTestCase {
    @MainActor
    func testTaskGroupingAndKeyboardOrderInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-demoData", "YES", "-uiAppearance", appearance, "-uiTaskGroupingDemo", "YES",
                "-uiRecordSourceOpens", "YES",
                "-demoNow", "2026-11-18T12:00:00Z",
            ]
            app.launch()
            defer { app.terminate() }
            let grouping = app.descendants(matching: .any).matching(identifier: "task-grouping-menu").firstMatch
            XCTAssertTrue(grouping.waitForExistence(timeout: 15))
            grouping.click()
            let dueDate = app.menuItems["Due date"]
            XCTAssertTrue(dueDate.waitForExistence(timeout: 5))
            dueDate.click()
            XCTAssertTrue(dueDate.waitForNonExistence(timeout: 5))
            XCTAssertTrue(section("inbox", in: app).waitForExistence(timeout: 15))
            XCTAssertTrue(section("overdue", in: app).waitForExistence(timeout: 5))
            XCTAssertFalse(row("group-completed", in: app).exists)
            let inbox = row("group-inbox", in: app)
            let overdue = row("group-overdue", in: app)
            XCTAssertTrue(inbox.exists)
            XCTAssertTrue(overdue.exists)
            XCTAssertLessThan(inbox.frame.minY, overdue.frame.minY)
            XCTAssertTrue(app.buttons["task-triage-date-group-inbox"].exists)
            XCTAssertTrue(app.buttons["task-triage-indefinite-group-inbox"].exists)
            XCTAssertFalse(inbox.descendants(matching: .any)
                .matching(identifier: "task-category-chip-inbox").firstMatch.exists)
            let chip = overdue.descendants(matching: .any)
                .matching(identifier: "task-category-chip-demo-finance").firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 5))
            XCTAssertEqual(chip.value as? String, "Category: Personal Finance")
            let categorizedInbox = row("group-categorized-inbox", in: app)
            let inboxChip = categorizedInbox.descendants(matching: .any)
                .matching(identifier: "task-category-chip-demo-eng").firstMatch
            XCTAssertTrue(inboxChip.exists)
            XCTAssertEqual(inboxChip.value as? String, "Category: Work Engineering")
            XCTAssertTrue(categorizedInbox.label.hasSuffix(", Inbox"))
            XCTAssertTrue(categorizedInbox.isHittable)
            XCTAssertTrue(overdue.isHittable)
            let overduePosition = overdue.frame.minY
            let editorTitle = app.textFields["task-title"]
            categorizedInbox.click()
            XCTAssertTrue(editorTitle.waitForExistence(timeout: 5))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(editorTitle.waitForNonExistence(timeout: 5))
            XCTAssertEqual(overdue.frame.minY, overduePosition, accuracy: 2)
            XCTAssertTrue(overdue.isHittable)
            overdue.click()
            XCTAssertTrue(editorTitle.waitForExistence(timeout: 5))
            XCTAssertEqual(editorTitle.value as? String, "Group overdue task")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(editorTitle.waitForNonExistence(timeout: 5))
            XCTAssertEqual(overdue.frame.minY, overduePosition, accuracy: 2)
            capture("task-grouping-due-\(appearance)")

            app.typeKey("g", modifierFlags: [])
            app.typeKey("t", modifierFlags: [])
            app.typeKey("g", modifierFlags: [])
            app.typeKey("g", modifierFlags: [])
            let expected = [
                ("group-categorized-inbox", "Group categorized inbox task"),
                ("group-inbox", "Group inbox task"),
                ("group-overdue", "Group overdue task"),
                ("group-today-early", "Group today early"),
                ("group-today-hard", "Group today hard"),
                ("group-today-soft", "Group today soft"),
                ("group-pinned", "Group pinned task"),
                ("group-tomorrow", "Group tomorrow task"),
                ("group-this-week", "Group this week task"),
                ("group-next-week", "Group next week task"),
                ("group-later", "Group later task"),
                ("group-no-due", "Group no due task"),
                ("group-someday", "Group someday task"),
            ]
            for (index, item) in expected.enumerated() {
                if index > 0 { app.typeKey("j", modifierFlags: []) }
                assertSelected(item.0, title: item.1, in: app)
                if item.0 == "group-today-early" || item.0 == "group-today-soft" {
                    XCTAssertLessThanOrEqual(row(item.0, in: app).frame.height, 56, "Metadata must not add a line")
                }
                if item.0 == "group-today-soft" {
                    XCTAssertEqual(app.scrollViews["task-pane-scroll"].frame.width, 320, accuracy: 1)
                    XCTAssertFalse(row(item.0, in: app).descendants(matching: .any)
                        .matching(identifier: "task-context-group-today-soft").firstMatch.exists)
                    let due = row(item.0, in: app).staticTexts
                        .matching(NSPredicate(format: "value MATCHES %@", ".*[0-9]{1,2}:[0-9]{2}.*")).firstMatch
                    XCTAssertTrue(due.exists, "The due phrase must remain visible, not collapse to an icon")
                    XCTAssertGreaterThan(due.frame.width, 40)
                    XCTAssertLessThanOrEqual(due.frame.height, 16)
                    let source = row(item.0, in: app).descendants(matching: .any)
                        .matching(identifier: "task-source-group-today-soft").firstMatch
                    XCTAssertTrue(source.exists)
                    XCTAssertGreaterThan(source.frame.width, 5)
                    XCTAssertGreaterThan(source.frame.height, 5)
                    app.typeKey("g", modifierFlags: [])
                    app.typeKey("s", modifierFlags: [])
                    XCTAssertTrue(app.staticTexts["Opened source: https://example.com/grouping"].waitForExistence(timeout: 5))
                    XCTAssertFalse(app.sheets.firstMatch.exists)
                }
                if item.0 == "group-pinned" || item.0 == "group-no-due" {
                    let date = row(item.0, in: app).descendants(matching: .any)
                        .matching(identifier: "task-list-date-\(item.0)").firstMatch
                    XCTAssertTrue(date.exists)
                    XCTAssertTrue((date.value as? String)?.hasPrefix(item.0 == "group-pinned" ? "Pinned " : "Start ") == true)
                    XCTAssertLessThanOrEqual(row(item.0, in: app).frame.height, 56)
                }
            }
            app.typeKey("k", modifierFlags: [])
            assertSelected("group-no-due", title: "Group no due task", in: app)
            app.typeKey("g", modifierFlags: .shift)
            assertSelected("group-someday", title: "Group someday task", in: app)
            XCTAssertTrue(section("someday", in: app).exists)
            XCTAssertFalse(section("no-due-date", in: app).exists)

            app.typeKey("f", modifierFlags: [])
            let jump = app.staticTexts["task-jump-group-someday"]
            XCTAssertTrue(jump.waitForExistence(timeout: 5))
            let pane = app.scrollViews["task-pane-scroll"]
            XCTAssertTrue(pane.exists)
            let labels = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-jump-"))
            for label in labels.allElementsBoundByIndex {
                XCTAssertGreaterThanOrEqual(label.frame.minY, pane.frame.minY + 34)
                XCTAssertLessThanOrEqual(label.frame.maxY, pane.frame.maxY)
            }
            let keys = try XCTUnwrap(jump.value as? String).lowercased()
            XCTAssertFalse(keys.isEmpty)
            for key in keys { app.typeKey(String(key), modifierFlags: []) }
            let title = app.sheets.textFields.firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, "Group someday task")
            XCTAssertEqual((app.checkBoxes["task-someday"].value as? NSNumber)?.intValue, 1)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))

            app.typeKey("g", modifierFlags: [])
            app.typeKey("o", modifierFlags: [])
            app.typeKey("g", modifierFlags: .shift)
            assertSelected("group-next-week", title: "Group next week task", in: app)
            app.typeKey("g", modifierFlags: [])
            app.typeKey("g", modifierFlags: [])
            assertSelected("group-categorized-inbox", title: "Group categorized inbox task", in: app)
            XCTAssertTrue(section("category:demo-eng", in: app).exists)
            XCTAssertTrue(inboxChip.waitForExistence(timeout: 5))
            XCTAssertEqual(inboxChip.value as? String, "Category: Work Engineering")
            app.typeKey("j", modifierFlags: [])
            assertSelected("group-inbox", title: "Group inbox task", in: app)
            app.typeKey("j", modifierFlags: [])
            assertSelected("group-today-soft", title: "Group today soft", in: app)
            XCTAssertFalse(row("group-today-soft", in: app).descendants(matching: .any)
                .matching(identifier: "task-category-chip-demo-eng").firstMatch.exists)
            app.typeKey("g", modifierFlags: [])
            app.typeKey("g", modifierFlags: [])
            assertSelected("group-categorized-inbox", title: "Group categorized inbox task", in: app)
            capture("task-grouping-category-\(appearance)")

            app.typeKey("k", modifierFlags: .command)
            let search = app.textFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.typeText("Group by due date / category")
            XCTAssertTrue(app.staticTexts["Group by due date / category"].exists)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(search.waitForNonExistence(timeout: 5))
            XCTAssertTrue(section("overdue", in: app).waitForExistence(timeout: 5))

            app.typeKey("g", modifierFlags: [])
            app.typeKey("o", modifierFlags: [])
            app.terminate()
            app.launch()
            XCTAssertTrue(section("category:demo-eng", in: app).waitForExistence(timeout: 15))
            XCTAssertFalse(section("overdue", in: app).exists)
            app.typeKey("g", modifierFlags: [])
            app.typeKey("o", modifierFlags: [])
            XCTAssertTrue(section("overdue", in: app).waitForExistence(timeout: 5))
        }
    }

    @MainActor
    private func row(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "task-row-\(id)").firstMatch
    }

    @MainActor
    private func section(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "task-section-\(id)").firstMatch
    }

    @MainActor
    private func assertSelected(_ id: String, title: String, in app: XCUIApplication) {
        let item = row(id, in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "label IN %@", ["Selected task, \(title), Inbox", "Selected task, \(title), Categorized"] as NSArray),
                              evaluatedWith: item)], timeout: 5)
        let pane = app.scrollViews["task-pane-scroll"]
        XCTAssertGreaterThanOrEqual(item.frame.minY + 9, pane.frame.minY + 34)
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
