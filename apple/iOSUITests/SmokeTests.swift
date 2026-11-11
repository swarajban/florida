import XCTest

/// Wait for real content before capturing; a fixed launch delay can silently save a blank screen.
final class SmokeTests: XCTestCase {
    @MainActor
    func testCompletionStampAndQuarterHourPicker() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, mode: "day")
            waitForText("Infra offsite", in: app)
            app.tabBars.buttons["Tasks"].tap()
            let task = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Renew VPN certificate")).firstMatch
            XCTAssertTrue(task.waitForExistence(timeout: 10))
            task.tap()
            app.buttons["Mark done"].tap()
            app.tabBars.buttons["Agenda"].tap()
            let stamp = app.buttons["Renew VPN certificate, done"]
            XCTAssertTrue(stamp.waitForExistence(timeout: 10))
            XCTAssertTrue(stamp.isHittable, "an unscheduled task is stamped at now, in the visible grid")
            XCTAssertTrue((stamp.value as? String)?.hasPrefix("Done at ") == true)
            capture(app, "completed-at-now-\(appearance)")
            stamp.tap()
            app.buttons["Reopen"].tap()
            XCTAssertTrue(stamp.waitForNonExistence(timeout: 5))

            app.buttons["agenda-add"].tap()
            app.buttons["New Event"].tap()
            let title = app.textFields["Title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.typeText("Time picker check\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            let dateButtons = app.datePickers["event-start"].buttons
            dateButtons.element(boundBy: dateButtons.count - 1).tap()
            XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 5))
            let minute = app.pickerWheels.element(boundBy: 1)
            minute.adjust(toPickerWheelValue: "15")
            XCTAssertEqual(minute.value as? String, "15 minutes")
            // Move one row without momentum: a one-minute wheel would select 16, not 30.
            let middle = minute.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -34)),
                         withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertEqual(minute.value as? String, "30 minutes")
            capture(app, "quarter-hour-picker-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testThreeDayNavigation() {
        continueAfterFailure = false
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, mode: "threeDays")
            waitForText("Infra offsite", in: app)
            capture(app, "three-day-start-\(appearance)")
            let heading = app.buttons["Go to day"]
            let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.55))
            let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.55))
            let todayHeader = element(today.formatted(.dateTime.weekday(.wide).month(.wide).day()), in: app)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: today)!
            let nextHeader = element(nextDay.formatted(.dateTime.weekday(.wide).month(.wide).day()), in: app)
            let oneColumn = nextHeader.frame.midX - todayHeader.frame.midX
            XCTAssertGreaterThan(oneColumn, 0)
            let postmortem = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Draft incident postmortem")).firstMatch
            XCTAssertTrue(postmortem.isHittable)
            let beforeVerticalScroll = postmortem.frame.minY
            let gutter = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.7))
            gutter.press(forDuration: 0.05, thenDragTo: gutter.withOffset(CGVector(dx: 0, dy: -80)),
                         withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertLessThan(postmortem.frame.minY, beforeVerticalScroll - 50)
            let originalY = postmortem.frame.minY
            right.press(forDuration: 0.05, thenDragTo: right.withOffset(CGVector(dx: -oneColumn, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 1)
            // Yesterday's block is behind the fixed gutter, not an invisible tap target there.
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 25, dy: originalY + 10)).tap()
            XCTAssertFalse(app.buttons["Cancel"].exists)
            left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: oneColumn, dy: 0)),
                       withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 1)
            right.tap()
            XCTAssertTrue(app.navigationBars["New Event"].waitForExistence(timeout: 5))
            let thirdDay = calendar.date(byAdding: .day, value: 2, to: today)!
            XCTAssertTrue(app.datePickers["event-start"].buttons[
                thirdDay.formatted(.dateTime.month(.abbreviated).day().year())].exists)
            app.buttons["Cancel"].tap()
            // Drag exactly two measured columns, then stop before releasing. XCTest's .slow
            // is still 250 pt/s and can coast another day on newer iOS runtimes. Test inertia
            // separately below; this checks distance tracking and replenishing the runway.
            for (offset, forward) in [
                (2, true), (4, true), (6, true), (4, false), (2, false), (0, false),
                (-2, false), (-4, false), (-6, false), (-4, true), (-2, true), (0, true),
            ] {
                let from = forward ? right : left
                let to = from.withOffset(CGVector(dx: (forward ? -2 : 2) * oneColumn, dy: 0))
                from.press(forDuration: 0.05, thenDragTo: to,
                           withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 1)
                let date = calendar.date(byAdding: .day, value: offset, to: today)!
                let expected = date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
                XCTAssertTrue(heading.waitForExistence(timeout: 5))
                XCTAssertEqual(heading.value as? String, expected, "The calendar must follow the distance dragged")
            }
            XCTAssertEqual(postmortem.frame.minY, originalY, accuracy: 2, "Horizontal movement must retain the hour position")
            postmortem.tap()
            XCTAssertTrue(app.buttons["Mark done"].waitForExistence(timeout: 5))
            app.buttons["Cancel"].tap()
            let oldTime = postmortem.value as? String
            let blockCenter = postmortem.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            blockCenter.press(forDuration: 0.5, thenDragTo: blockCenter.withOffset(CGVector(dx: 0, dy: 30)),
                              withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertNotEqual(postmortem.value as? String, oldTime, "Holding still must move the task rather than scroll")
            XCTAssertEqual(postmortem.frame.minY, originalY + 30, accuracy: 15, "The task should move by half an hour")
            // Native inertia can carry a flick farther than the same slow drag.
            right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
            let fartherDays = (3...7).map { offset in
                calendar.date(byAdding: .day, value: offset, to: today)!
                    .formatted(.dateTime.weekday(.wide).month(.wide).day().year())
            }
            XCTAssertTrue(fartherDays.contains(heading.value as? String ?? ""), "A flick must coast across multiple days")
            capture(app, "three-day-coasted-\(appearance)")
            let coastedDay = heading.value as? String
            app.tabBars.buttons["Tasks"].tap()
            app.tabBars.buttons["Agenda"].tap()
            XCTAssertEqual(heading.value as? String, coastedDay)
            app.buttons["Today"].tap()
            XCTAssertEqual(heading.value as? String, today.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
            XCTAssertTrue(postmortem.isHittable)
            // Three column labels replace the seven-day strip, rather than sitting below it.
            XCTAssertFalse(app.buttons[today.formatted(.dateTime.weekday(.wide).month(.wide).day())].exists)
            capture(app, "three-day-return-\(appearance)")
            // Choosing a date outside the preloaded range, and Today afterwards, replace it.
            heading.tap()
            XCTAssertTrue(app.buttons["Next Month"].waitForExistence(timeout: 5))
            app.buttons["Next Month"].tap()
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: today)!
            let distantDay = calendar.date(bySetting: .day, value: 15, of: nextMonth)!
            let distantChoice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@",
                distantDay.formatted(.dateTime.weekday(.wide).month(.wide).day()))).firstMatch
            XCTAssertTrue(distantChoice.waitForExistence(timeout: 5))
            distantChoice.tap()
            XCTAssertEqual(heading.value as? String, distantDay.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
            app.buttons["Today"].tap()
            XCTAssertTrue(postmortem.isHittable)
            // The single-day control still pages by one day, then re-enters the carousel there.
            app.segmentedControls["agenda-mode"].buttons["Day"].tap()
            right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0.3)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            XCTAssertEqual(heading.value as? String, tomorrow.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
            app.segmentedControls["agenda-mode"].buttons["3 Days"].tap()
            XCTAssertTrue(app.buttons["Architecture sync"].exists)
            app.buttons["Today"].tap()
            XCTAssertTrue(postmortem.isHittable)
            app.terminate()
        }
    }

    @MainActor
    func testTaskShortcutAndRecurringEvent() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            waitForText("Infra offsite", in: app)
            app.open(URL(string: "florida://tasks/new")!)
            XCTAssertTrue(app.navigationBars["New Task"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["Add"].exists)
            capture(app, "widget-add-task-\(appearance)")
            app.buttons["Cancel"].tap()
            app.open(URL(string: "florida://agenda")!)
            app.buttons["agenda-add"].tap()
            app.buttons["New Event"].tap()
            let title = app.textFields["Title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.tap()
            title.typeText("Weekly planning\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            let calendarPicker = app.buttons["event-calendar"]
            XCTAssertTrue(calendarPicker.label.contains("demo@sempre-health.com"), calendarPicker.debugDescription)
            calendarPicker.tap()
            let choices = ["demo@sempre-health.com", "demo@personal.example", "A&S Family Calendar", "teammate@sempre-health.com"]
                .map { app.buttons[$0] }
            XCTAssertTrue(choices.allSatisfy(\.exists))
            let tops = choices.map(\.frame.minY)
            XCTAssertEqual(tops, tops.sorted())
            capture(app, "calendar-order-\(appearance)")
            choices[0].tap()
            XCTAssertTrue(app.buttons["A&S Family Calendar"].waitForNonExistence(timeout: 5))
            let repeatPicker = app.buttons["event-repeat"]
            XCTAssertTrue(repeatPicker.waitForExistence(timeout: 5))
            repeatPicker.tap()
            XCTAssertTrue(app.buttons["Weekly"].waitForExistence(timeout: 5))
            app.buttons["Weekly"].tap()
            XCTAssertTrue(app.buttons["Monthly"].waitForNonExistence(timeout: 5))
            waitForText("Every 1 week", in: app)
            app.buttons["event-repeat-interval-Increment"].tap()
            waitForText("Every 2 weeks", in: app)
            capture(app, "event-recurring-\(appearance)")
            app.navigationBars["New Event"].buttons["Add"].tap()
            XCTAssertTrue(app.navigationBars["New Event"].waitForNonExistence(timeout: 5))
            waitForText("Weekly planning", in: app)
            app.terminate()
        }
    }

    @MainActor
    func testScreensInBothAppearances() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            waitForText("Infra offsite", in: app)
            capture(app, "agenda-\(appearance)")

            app.tabBars.buttons["Tasks"].tap()
            waitForText("Renew VPN certificate", in: app)
            capture(app, "tasks-\(appearance)")
            app.tabBars.buttons["Settings"].tap()
            waitForText("Save and sync", in: app)
            capture(app, "settings-\(appearance)")
            app.terminate()

            let grid = launch(appearance: appearance, mode: "threeDays")
            waitForText("Infra offsite", in: grid)
            capture(grid, "agenda-3day-\(appearance)")
            grid.terminate()

            let event = launch(appearance: appearance, sheet: "event")
            let join = event.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Join meeting")).firstMatch
            XCTAssertTrue(join.waitForExistence(timeout: 20))
            waitForText("Design review: scheduler v2", in: event)
            capture(event, "event-detail-\(appearance)")
            event.terminate()

            let draft = launch(appearance: appearance, tab: "tasks", sheet: "aitask")
            waitForText("How AI read it", in: draft)
            XCTAssertTrue(draft.buttons["Add"].exists)
            capture(draft, "task-draft-\(appearance)")
            draft.terminate()

            let picker = launch(appearance: appearance, sheet: "daypicker")
            waitForText("Go to Day", in: picker)
            XCTAssertTrue(picker.buttons["Done"].waitForExistence(timeout: 20))
            capture(picker, "day-picker-\(appearance)")
            picker.terminate()
        }

        let large = launch(largeText: true)
        waitForText("Infra offsite", in: large)
        capture(large, "agenda-large-text")
        large.tabBars.buttons["Tasks"].tap()
        waitForText("Renew VPN certificate", in: large)
        capture(large, "tasks-large-text")
        large.terminate()
    }

    /// Projects, parallel lanes, the gym, the brief and the task editor's plan fields.
    @MainActor
    func testPlanScreensInBothAppearances() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let agenda = launch(appearance: appearance)
            XCTAssertTrue(element("agenda-brief", in: agenda).waitForExistence(timeout: 20))
            XCTAssertTrue(element("agenda-day-kind", in: agenda).exists)
            capture(agenda, "plan-agenda-\(appearance)")
            // The shared hour sits below the brief and the morning.
            agenda.swipeUp()
            capture(agenda, "plan-agenda-lanes-\(appearance)")
            // Tomorrow is all ahead, so nothing is dimmed: a meeting's card among open task rows.
            agenda.swipeLeft()
            waitForText("Architecture sync", in: agenda)
            // The meeting is after lunch, under the tab bar until the list scrolls.
            agenda.swipeUp()
            capture(agenda, "plan-agenda-tomorrow-\(appearance)")
            agenda.terminate()

            let day = launch(appearance: appearance, mode: "day")
            // A plan block's identifier ends in its start time, which follows the day the test runs.
            XCTAssertTrue(element(startingWith: "grid-plan-commitment:", in: day).waitForExistence(timeout: 20))
            let lanes = element(startingWith: "grid-plan-project:demo-project-vendor@", in: day)
            XCTAssertTrue(lanes.exists)
            // The grid opens around now. Drag it by the hour labels, slowly so it does not
            // coast, until the shared hour and the gym are clear of the tab bar.
            let height = day.windows.firstMatch.frame.height
            for _ in 0..<6 where lanes.frame.maxY > height * 0.6 {
                let from = day.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.8))
                let to = day.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.6))
                from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
            }
            capture(day, "plan-day-grid-\(appearance)")
            day.terminate()

            let projects = launch(appearance: appearance, tab: "tasks", sheet: "projects")
            waitForText("Home network rebuild", in: projects)
            XCTAssertTrue(element("project-row-demo-project-auth", in: projects).exists)
            capture(projects, "projects-\(appearance)")
            projects.terminate()

            let editor = launch(appearance: appearance, tab: "tasks", sheet: "project")
            XCTAssertTrue(element("project-name", in: editor).waitForExistence(timeout: 20))
            XCTAssertTrue(element("project-parallel", in: editor).exists)
            capture(editor, "project-editor-\(appearance)")
            editor.terminate()

            let tasks = launch(appearance: appearance, tab: "tasks")
            let row = tasks.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fix flaky scheduler test")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            row.tap()
            XCTAssertTrue(tasks.buttons["Mark done"].waitForExistence(timeout: 20))
            // Mark done, then both dates, before any scrolling.
            XCTAssertTrue(element("task-start-add", in: tasks).isHittable)
            XCTAssertTrue(element("task-due-date", in: tasks).isHittable)
            capture(tasks, "task-editor-\(appearance)")
            let project = element("task-project", in: tasks)
            for _ in 0..<4 where !(project.exists && project.isHittable) {
                tasks.swipeUp()
            }
            XCTAssertTrue(project.isHittable)
            XCTAssertTrue(element("task-attention", in: tasks).exists)
            capture(tasks, "task-plan-fields-\(appearance)")
            tasks.terminate()
        }
    }

    /// Categories in list order on their own screen and in the task editor's picker, and a start
    /// date added to an overdue task.
    @MainActor
    func testCategoryOrderAndTaskDates() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, tab: "tasks")
            let overdue = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Renew VPN certificate")).firstMatch
            XCTAssertTrue(overdue.waitForExistence(timeout: 20))
            app.navigationBars.buttons["Categories"].tap()
            // Work before personal, each by name. The demo data's stored order has Personal
            // Finance before Home.
            let rows = ["Work Engineering", "Work Infosec", "Home", "Personal Finance"].map { name in
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            }
            XCTAssertTrue(rows[0].waitForExistence(timeout: 20))
            let tops = rows.map(\.frame.minY)
            XCTAssertEqual(tops, tops.sorted())
            capture(app, "categories-\(appearance)")
            app.navigationBars.buttons.firstMatch.tap()

            XCTAssertTrue(overdue.waitForExistence(timeout: 20))
            overdue.tap()
            // Due yesterday: a start of today is past it, so the due date moves to tomorrow.
            let addStart = element("task-start-add", in: app)
            XCTAssertTrue(addStart.waitForExistence(timeout: 20))
            addStart.tap()
            XCTAssertTrue(element("task-start-date", in: app).waitForExistence(timeout: 5))
            capture(app, "task-editor-start-added-\(appearance)")

            element("task-category", in: app).tap()
            XCTAssertTrue(app.buttons["Personal Finance"].waitForExistence(timeout: 5))
            capture(app, "task-category-picker-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func element(startingWith prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    private func launch(
        appearance: String = "light", tab: String = "agenda", sheet: String? = nil, mode: String = "list", largeText: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        // The agenda mode is always passed: the app remembers the last one in the App Group
        // defaults, which the simulator keeps between the launches of one test run.
        app.launchArguments = ["-demoData", "YES", "-uiTab", tab, "-uiAppearance", appearance, "-uiAgendaMode", mode]
        if let sheet { app.launchArguments += ["-uiSheet", sheet] }
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            largeText ? "UICTContentSizeCategoryXXXL" : "UICTContentSizeCategoryL",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func waitForText(_ text: String, in app: XCUIApplication) {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Missing \(text)")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
