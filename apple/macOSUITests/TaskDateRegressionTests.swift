import XCTest

final class TaskDateRegressionTests: XCTestCase {
    @MainActor
    func testSavedDatesAndDraftIsolationInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            defer { app.terminate() }
            assertFutureRow(in: app)
            row(in: app).staticTexts["Updated account task"].click()
            XCTAssertTrue(app.buttons["task-due"].waitForExistence(timeout: 5))
            chooseDue("nov 11 2026", in: app)
            assertFutureRow(in: app)
            capture("task-date-unsaved-\(appearance)")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            assertFutureRow(in: app)

            row(in: app).staticTexts["Updated account task"].click()
            XCTAssertTrue(app.buttons["task-due"].waitForExistence(timeout: 5))
            chooseDue("nov 11 2026", in: app)
            app.sheets.buttons["Save"].click()
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertTrue(section("overdue", in: app).waitForExistence(timeout: 5))
            XCTAssertTrue(row(in: app).staticTexts["Overdue"].waitForExistence(timeout: 5))
            XCTAssertTrue(row(in: app).staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Nov 11"))
                .firstMatch.exists)

            row(in: app).staticTexts["Updated account task"].click()
            XCTAssertTrue(app.buttons["task-due"].waitForExistence(timeout: 5))
            chooseDue("nov 17 2026", in: app)
            app.sheets.buttons["Save"].click()
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            assertFutureRow(dueText: savedFutureDueText, in: app)
            row(in: app).staticTexts["Updated account task"].click()
            XCTAssertTrue(app.buttons["task-due"].waitForExistence(timeout: 5))
            XCTAssertTrue((app.buttons["task-due"].value as? String)?.contains("Nov 17") == true)
            app.sheets.buttons["Cancel"].click()
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            assertFutureRow(dueText: savedFutureDueText, in: app)
            capture("task-date-saved-\(appearance)")
        }
    }

    @MainActor
    func testSyncedDateRefreshesTheRowWhileAnOldDraftIsOpen() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance, extra: ["-uiTaskDatePast", "YES", "-uiEditorDiagnostics", "YES",
                                                 "-uiTaskDateSyncDuringTyping", "YES"])
            defer { app.terminate() }
            XCTAssertTrue(row(in: app).staticTexts["Overdue"].waitForExistence(timeout: 5))
            row(in: app).staticTexts["Updated account task"].click()
            let title = app.textFields["task-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            let oldDraftDate = app.buttons["task-due"].value as? String
            title.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Unsaved title")
            let diagnostic = app.staticTexts["editor-diagnostics"]
            wait(for: [expectation(for: NSPredicate(format: "value CONTAINS %@", "syncApplied=true"),
                                  evaluatedWith: diagnostic)], timeout: 5)
            assertFutureRow(in: app)
            XCTAssertEqual(app.buttons["task-due"].value as? String, oldDraftDate)
            XCTAssertEqual(title.value as? String, "Unsaved title")
            capture("task-date-sync-draft-\(appearance)")
            app.sheets.buttons["Cancel"].click()
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            assertFutureRow(in: app)
            row(in: app).staticTexts["Updated account task"].click()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, "Updated account task")
            XCTAssertNotEqual(app.buttons["task-due"].value as? String, oldDraftDate)
            app.sheets.buttons["Cancel"].click()
        }
    }

    @MainActor
    func testClicksAndJumpLabelsNeverLeaveMultipleSelections() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance, extra: ["-uiTaskDateSelectionDemo", "YES"])
            defer { app.terminate() }
            assertSelectedOnly(nil, in: app)
            for id in ["date-updated", "date-other"] {
                row(id, in: app).staticTexts.firstMatch.click()
                XCTAssertTrue(app.buttons["task-due"].waitForExistence(timeout: 5))
                assertSelectedOnly(id, in: app)
                app.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
                assertSelectedOnly(id, in: app)
            }
            app.typeKey("f", modifierFlags: [])
            let badge = app.staticTexts["task-jump-date-updated"]
            XCTAssertTrue(badge.waitForExistence(timeout: 5))
            assertSelectedOnly("date-other", in: app)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(badge.waitForNonExistence(timeout: 5))
            assertSelectedOnly("date-other", in: app)
            capture("task-selection-switched-\(appearance)")

            app.typeKey(.escape, modifierFlags: [])
            assertSelectedOnly(nil, in: app)
            for _ in 0..<2 {
                app.typeKey("f", modifierFlags: [])
                XCTAssertTrue(badge.waitForExistence(timeout: 5))
                assertSelectedOnly(nil, in: app)
                app.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(badge.waitForNonExistence(timeout: 5))
                assertSelectedOnly(nil, in: app)
                XCTAssertFalse(app.sheets.firstMatch.exists)
            }
            app.typeKey("f", modifierFlags: [])
            XCTAssertTrue(badge.waitForExistence(timeout: 5))
            let keys = try XCTUnwrap(badge.value as? String).lowercased()
            XCTAssertFalse(keys.isEmpty)
            for key in keys { app.typeKey(String(key), modifierFlags: []) }
            XCTAssertTrue(app.buttons["task-due"].waitForExistence(timeout: 5))
            assertSelectedOnly("date-updated", in: app)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            app.typeKey("f", modifierFlags: [])
            XCTAssertTrue(badge.waitForExistence(timeout: 5))
            assertSelectedOnly("date-updated", in: app)
            app.typeKey(.escape, modifierFlags: [])
            assertSelectedOnly("date-updated", in: app)
            capture("task-jump-cancel-\(appearance)")
        }
    }

    @MainActor
    func testSaveReopenAndSchedulerReplyRefreshTheSameRow() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance, extra: ["-uiTaskDatePast", "YES", "-uiTaskDateNoPlacement", "YES",
                                                 "-uiEditorDiagnostics", "YES", "-uiTaskDateSyncDuringTyping", "YES"])
            defer { app.terminate() }
            XCTAssertTrue(row(in: app).staticTexts["Overdue"].waitForExistence(timeout: 5))
            row(in: app).staticTexts["Updated account task"].click()
            XCTAssertTrue(app.buttons["task-due"].waitForExistence(timeout: 5))
            chooseDue("nov 17 2026", in: app)
            app.sheets.buttons["Save"].click()
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            assertFutureRow(dueText: savedFutureDueText, hasPlacement: false, in: app)
            row(in: app).staticTexts["Updated account task"].click()
            let title = app.textFields["task-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertTrue((app.buttons["task-due"].value as? String)?.contains("Nov 17") == true)
            assertFutureRow(dueText: savedFutureDueText, hasPlacement: false, in: app)
            capture("task-date-before-scheduler-\(appearance)")
            title.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Unsaved scheduler draft")
            let diagnostic = app.staticTexts["editor-diagnostics"]
            wait(for: [expectation(for: NSPredicate(format: "value CONTAINS %@", "syncApplied=true"),
                                  evaluatedWith: diagnostic)], timeout: 5)
            assertFutureRow(dueText: savedFutureDueText, in: app)
            app.sheets.buttons["Cancel"].click()
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            assertFutureRow(dueText: savedFutureDueText, in: app)
            capture("task-date-after-scheduler-\(appearance)")
        }
    }

    @MainActor
    private func launch(_ appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiTaskDateDemo", "YES", "-uiAppearance", appearance,
                               "-demoNow", "2026-11-13T17:00:00Z"] + extra
        app.launch()
        let grouping = app.descendants(matching: .any).matching(identifier: "task-grouping-menu").firstMatch
        XCTAssertTrue(grouping.waitForExistence(timeout: 15))
        grouping.click()
        app.menuItems["Due date"].click()
        XCTAssertTrue(row(in: app).waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func row(_ id: String = "date-updated", in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "task-row-\(id)").firstMatch
    }

    @MainActor
    private func section(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "task-section-\(id)").firstMatch
    }

    @MainActor
    private func assertFutureRow(dueText: String = "Tue", hasPlacement: Bool = true, in app: XCUIApplication) {
        XCTAssertTrue(section("next-week", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(section("overdue", in: app).exists)
        let due = row(in: app).staticTexts["task-due-label-date-updated"]
        XCTAssertTrue(due.waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "value == %@", dueText), evaluatedWith: due)], timeout: 5)
        XCTAssertFalse(row(in: app).staticTexts["Overdue"].exists)
        XCTAssertFalse(row(in: app).staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Nov 11"))
            .firstMatch.exists)
        let schedule = row(in: app).staticTexts["task-schedule-label-date-updated"]
        XCTAssertTrue(schedule.exists)
        if hasPlacement {
            wait(for: [expectation(for: NSPredicate(format: "value CONTAINS %@", "12:00"),
                                  evaluatedWith: schedule)], timeout: 5)
        } else {
            wait(for: [expectation(for: NSPredicate(format: "value == %@", "Unscheduled"),
                                  evaluatedWith: schedule)], timeout: 5)
        }
    }

    @MainActor
    private func chooseDue(_ text: String, in app: XCUIApplication) {
        app.buttons["task-due"].click()
        let search = app.textFields["task-due-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeText(text)
        wait(for: [expectation(for: NSPredicate(format: "value == %@", text), evaluatedWith: search)], timeout: 5)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
    }

    private var savedFutureDueText: String {
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 17))!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let clock = calendar.dateComponents([.hour, .minute], from: due)
        if clock.hour == 17 && clock.minute == 0 || clock.hour == 23 && clock.minute == 59 { return "Tue" }
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return "Tue \(due.formatted(style))"
    }

    @MainActor
    private func assertSelectedOnly(_ id: String?, in app: XCUIApplication) {
        for (taskID, title) in [("date-updated", "Updated account task"), ("date-other", "Other account task")] {
            let label = taskID == id ? "Selected task, \(title)" : "Task, \(title)"
            wait(for: [expectation(for: NSPredicate(format: "label == %@", label),
                                  evaluatedWith: row(taskID, in: app))], timeout: 5)
        }
        let selected = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "task-row-", "Selected task,"))
        XCTAssertEqual(selected.count, id == nil ? 0 : 1)
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
