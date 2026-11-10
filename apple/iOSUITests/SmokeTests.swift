import XCTest

/// Wait for real content before capturing; a fixed launch delay can silently save a blank screen.
final class SmokeTests: XCTestCase {
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
