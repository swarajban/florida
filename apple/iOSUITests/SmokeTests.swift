import XCTest
import UIKit

/// Wait for real content before capturing; a fixed launch delay can silently save a blank screen.
final class SmokeTests: XCTestCase {
    @MainActor
    func testTaskSourceCaptureAndRemoval() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, tab: "tasks")
            waitForText("Renew VPN certificate", in: app)
            app.buttons["New task"].tap()
            let input = app.textViews["quick-add-input"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("https://github.com/example/florida/pull/123")
            XCTAssertEqual(app.staticTexts["quick-add-title"].label, "PR #123 in example/florida")
            XCTAssertTrue(app.buttons["quick-add-remove-source"].exists)
            capture(app, "capture-source-\(appearance)")
            app.buttons["Details"].tap()
            let url = app.textFields["task-source-url"]
            XCTAssertTrue(url.waitForExistence(timeout: 5))
            XCTAssertEqual(url.value as? String, "https://github.com/example/florida/pull/123")
            app.buttons["task-editor-cancel"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["quick-add-remove-source"].exists)
            app.buttons["quick-add-remove-source"].tap()
            input.tap()
            input.typeText(" tomorrow")
            XCTAssertFalse(app.buttons["quick-add-remove-source"].exists)
            app.buttons["Cancel"].tap()
            app.buttons["New task"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["quick-add-remove-source"].exists, "Removing a source survives edits and cancellation")
            app.buttons["Details"].tap()
            XCTAssertTrue(app.buttons["task-source-add"].waitForExistence(timeout: 5))
            XCTAssertFalse(url.exists)
            app.buttons["task-editor-cancel"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            app.buttons["quick-add-save"].tap()
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "PR #123 in example/florida")).element
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertFalse(element(startingWith: "task-source-open-", in: app).exists)
            row.tap()
            XCTAssertTrue(app.buttons["task-source-add"].waitForExistence(timeout: 5))
            XCTAssertFalse(url.exists, "The removed source must not be saved")
            app.terminate()
        }
    }

    @MainActor
    func testTaskSourceEditAndOpen() {
        continueAfterFailure = false
        let app = launch(tab: "tasks", recordSourceOpens: true)
        waitForText("Renew VPN certificate", in: app)
        app.buttons["New task"].tap()
        let input = app.textViews["quick-add-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("Review source https://github.com/example/florida/pull/456")
        app.buttons["Details"].tap()
        let url = app.textFields["task-source-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        XCTAssertEqual(url.value as? String, "https://github.com/example/florida/pull/456")
        app.buttons["Add"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-row-' AND label BEGINSWITH %@", "Review source")).element
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let taskID = String(row.identifier.dropFirst("tasks-row-".count))
        let sourceButton = app.buttons["task-source-open-\(taskID)"]
        XCTAssertTrue(sourceButton.waitForExistence(timeout: 5))
        XCTAssertTrue(sourceButton.label.contains("PR #456"))
        sourceButton.tap()
        let opened = app.staticTexts["source-opened-url"]
        XCTAssertTrue(opened.waitForExistence(timeout: 5))
        XCTAssertEqual(opened.label, "https://github.com/example/florida/pull/456")
        XCTAssertFalse(app.navigationBars["Edit Task"].exists, "Opening the source must not also open the editor")

        row.tap()
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        for _ in 0..<3 where !url.isHittable { app.swipeUp() }
        replaceText(in: url, with: "javascript:alert(1)", in: app)
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        XCTAssertTrue(app.staticTexts["task-source-error"].exists)
        replaceText(in: url, with: "mailto:review@example.com", in: app)
        replaceText(in: app.textFields["task-source-title"], with: "Release discussion", in: app)
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        capture(app, "task-source-editor")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(sourceButton.waitForExistence(timeout: 5))
        XCTAssertEqual(sourceButton.label, "Open source: Release discussion")
        sourceButton.tap()
        XCTAssertEqual(opened.label, "mailto:review@example.com")
        XCTAssertFalse(app.navigationBars["Edit Task"].exists)
        row.tap()
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        XCTAssertEqual(url.value as? String, "mailto:review@example.com")
        XCTAssertEqual(app.textFields["task-source-title"].value as? String, "Release discussion")
        let remove = app.buttons["task-source-remove"]
        for _ in 0..<3 where !remove.isHittable { app.swipeUp() }
        remove.tap()
        app.buttons["task-editor-cancel"].tap()
        XCTAssertTrue(sourceButton.waitForExistence(timeout: 5), "Cancel must discard source edits")
        row.tap()
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        for _ in 0..<3 where !remove.isHittable { app.swipeUp() }
        remove.tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(sourceButton.exists, "Removing a source must persist after Save")
        row.tap()
        XCTAssertTrue(app.buttons["task-source-add"].waitForExistence(timeout: 5))
        XCTAssertFalse(url.exists)
        app.terminate()
    }

    @MainActor
    func testEventResourcesInBothAppearances() {
        continueAfterFailure = false
        let expected = [
            ("https://docs.google.com/document/d/demo-scheduler/edit", "Scheduler v2 RFC, Google Docs"),
            ("https://docs.google.com/spreadsheets/d/demo-capacity/edit", "Capacity model, Google Sheets"),
            ("https://docs.google.com/presentation/d/demo-review/edit", "Review slides, Google Slides"),
            ("https://www.notion.so/demo/decisions", "Decision log, Notion"),
            ("https://www.figma.com/design/demo/calendar", "Calendar mockups, Figma"),
            ("https://github.com/example/florida/pull/42", "Scheduler implementation, GitHub"),
            ("https://linear.app/demo/issue/DEMO-21", "Scheduler follow-up, Linear"),
            ("https://notes.example.com/design-review", "notes.example.com, notes.example.com"),
            ("https://zoom.us/j/123456789", "Backup room, Zoom"),
            ("https://meet.google.com/alt-room-xyz", "Breakout room, Google Meet"),
            ("https://wiki.example.com/scheduler", "Scheduler runbook, wiki.example.com"),
        ]
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, sheet: "event", recordResourceOpens: true)
            let document = app.buttons["event-resource-\(expected[0].0)"]
            XCTAssertTrue(document.waitForExistence(timeout: 20))
            for _ in 0..<4 where !document.isHittable { app.swipeUp() }
            XCTAssertTrue(document.isHittable)
            XCTAssertEqual(document.label, expected[0].1)
            XCTAssertEqual(app.buttons.matching(identifier: document.identifier).count, 1)
            XCTAssertFalse(app.buttons["event-resource-https://meet.google.com/abc-defg-hij"].exists)
            capture(app, "event-resources-\(appearance)")
            document.tap()
            XCTAssertEqual(document.value as? String, "Opened \(expected[0].0)")

            for (url, title) in expected.dropFirst() {
                let resource = app.buttons["event-resource-\(url)"]
                for _ in 0..<6 where !resource.isHittable { app.swipeUp() }
                XCTAssertTrue(resource.waitForExistence(timeout: 5))
                XCTAssertTrue(resource.isHittable)
                XCTAssertEqual(resource.label, title)
                resource.tap()
                XCTAssertEqual(resource.value as? String, "Opened \(url)")
            }
            capture(app, "event-resources-scrolled-\(appearance)")
            app.buttons["Done"].tap()
            XCTAssertTrue(document.waitForNonExistence(timeout: 5))
            let lunch = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Lunch with Priya")).firstMatch
            for _ in 0..<5 where !lunch.isHittable { app.swipeUp() }
            XCTAssertTrue(lunch.waitForExistence(timeout: 5))
            lunch.tap()
            XCTAssertTrue(app.navigationBars["Event"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Resources"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testHiddenProtectedDayAndStoredReason() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let status = app.buttons["agenda-day-kind"]
            XCTAssertTrue(status.waitForExistence(timeout: 15))
            XCTAssertTrue((status.value as? String)?.contains("Public holiday. Automatic: US public holiday on your calendar.") == true)
            status.tap()
            let indicator = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "day-blocking-", "-demo-event-holiday")).firstMatch
            XCTAssertTrue(indicator.waitForExistence(timeout: 15))
            XCTAssertTrue(indicator.label.contains("Public holiday"))
            XCTAssertEqual(indicator.value as? String, "Automatic: US public holiday on your calendar.")
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Public holiday")).firstMatch.exists)
            capture(app, "protected-hidden-day-agenda-\(appearance)")
            indicator.tap()
            let choice = app.descendants(matching: .any).matching(identifier: "event-blocks-day-demo-event-holiday").firstMatch
            let reason = app.staticTexts["event-blocking-reason-demo-event-holiday"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertEqual(choice.value as? String, "Automatic")
            XCTAssertTrue(reason.label.contains("Automatic: US public holiday"))
            choice.descendants(matching: .any)["Does not block"].tap()
            XCTAssertTrue(reason.label.contains("Manual override: Does not block"))
            XCTAssertTrue(reason.label.contains("Automatic: US public holiday"))
            capture(app, "protected-day-manual-reason-\(appearance)")
            choice.descendants(matching: .any)["Automatic"].tap()
            XCTAssertEqual(choice.value as? String, "Automatic")
            XCTAssertTrue(reason.label.hasPrefix("Automatic: US public holiday"))
            XCTAssertEqual(app.staticTexts["event-blocks-day-effective-demo-event-holiday"].label, "Blocks your day")
            app.navigationBars.buttons["Done"].tap()
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            XCTAssertTrue((status.value as? String)?.contains("Public holiday. Automatic: US public holiday on your calendar.") == true)
            app.segmentedControls["agenda-mode"].buttons["3 Days"].tap()
            status.tap()
            XCTAssertTrue(indicator.waitForExistence(timeout: 5))
            XCTAssertTrue(indicator.isHittable)
            capture(app, "protected-hidden-day-columns-\(appearance)")
            indicator.tap()
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertTrue(reason.label.contains("Automatic: US public holiday"))
            app.terminate()
        }
    }

    @MainActor
    func testCompactAgendaWithOverlappingProtectedStays() {
        continueAfterFailure = false
        let calendar = Calendar.current
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 11, minute: 24))!
        let friday = calendar.date(byAdding: .day, value: -1, to: saturday)!
        let sunday = calendar.date(byAdding: .day, value: 1, to: saturday)!
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, mode: "day", demoNow: saturday, overlappingStays: true)
            let status = app.buttons["agenda-day-kind"]
            XCTAssertTrue(status.waitForExistence(timeout: 15))
            XCTAssertEqual(status.label, "Day off")
            XCTAssertTrue((status.value as? String)?.contains("Stay at Marshall. Automatic: Your trip · last day open") == true)
            XCTAssertFalse(app.buttons["Florida"].exists)
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "day-blocking-")).firstMatch.exists)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Protected ·")).firstMatch.exists)
            let marshall = app.buttons["all-day-event-demo-stay-marshall"]
            let tomales = app.buttons["all-day-event-demo-stay-tomales"]
            XCTAssertTrue(marshall.waitForExistence(timeout: 10))
            XCTAssertEqual(marshall.value as? String, "All day, Protected. Automatic: Your trip · last day open")
            XCTAssertEqual(tomales.value as? String, "All day, Protected. Automatic: Your trip · last day open")
            XCTAssertEqual(app.buttons.matching(identifier: marshall.identifier).count, 1)
            XCTAssertEqual(app.buttons.matching(identifier: tomales.identifier).count, 1)
            XCTAssertLessThan(tomales.frame.maxY, app.frame.height * 0.35)
            let heading = app.buttons["Go to day"]
            XCTAssertEqual(heading.frame.minY, app.buttons["agenda-add"].frame.minY, accuracy: 3)
            XCTAssertEqual(status.frame.midY, app.segmentedControls["agenda-mode"].frame.midY, accuracy: 3)
            capture(app, "agenda-overlapping-stays-day-\(appearance)")
            marshall.tap()
            XCTAssertTrue(app.staticTexts["event-blocking-reason-demo-stay-marshall"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["event-blocking-reason-demo-stay-marshall"].label, "Automatic: Your trip · last day open")
            app.navigationBars.buttons["Done"].tap()
            app.buttons[friday.formatted(.dateTime.weekday(.wide).month(.wide).day())].tap()
            XCTAssertEqual(status.label, "Protected")
            capture(app, "agenda-overlapping-stays-workday-\(appearance)")
            app.buttons["Today"].tap()
            XCTAssertEqual(status.label, "Day off")
            app.segmentedControls["agenda-mode"].buttons["3 Days"].tap()
            XCTAssertTrue(marshall.waitForExistence(timeout: 5))
            XCTAssertTrue((marshall.value as? String)?.contains("Protected. Automatic: Your trip · last day open") == true)
            XCTAssertEqual(app.buttons.matching(identifier: marshall.identifier).count, 1)
            XCTAssertEqual(app.buttons.matching(identifier: tomales.identifier).count, 1)
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "day-blocking-")).firstMatch.exists)
            capture(app, "agenda-overlapping-stays-three-days-\(appearance)")
            let sundayStatus = app.buttons["agenda-day-kind-2026-11-15"]
            XCTAssertTrue(sundayStatus.isHittable)
            XCTAssertEqual(sundayStatus.label, "Day off")
            XCTAssertTrue((sundayStatus.value as? String)?.contains("Hidden Sunday holiday. Automatic: US public holiday on your calendar.") == true)
            sundayStatus.tap()
            let hiddenHoliday = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "day-blocking-", "-demo-hidden-sunday")).firstMatch
            XCTAssertTrue(hiddenHoliday.waitForExistence(timeout: 5))
            hiddenHoliday.tap()
            XCTAssertTrue(app.staticTexts["event-blocking-reason-demo-hidden-sunday"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["event-blocking-reason-demo-hidden-sunday"].label, "Automatic: US public holiday on your calendar.")
            app.navigationBars.buttons["Done"].tap()
            app.segmentedControls["agenda-mode"].buttons["List"].tap()
            XCTAssertTrue(marshall.waitForExistence(timeout: 5))
            XCTAssertTrue((marshall.value as? String)?.contains("Protected. Automatic: Your trip · last day open") == true)
            XCTAssertEqual(app.buttons.matching(identifier: marshall.identifier).count, 1)
            XCTAssertEqual(app.buttons.matching(identifier: tomales.identifier).count, 1)
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "day-blocking-")).firstMatch.exists)
            capture(app, "agenda-overlapping-stays-list-\(appearance)")
            heading.tap()
            let sundayChoice = app.datePickers.buttons.matching(NSPredicate(
                format: "label CONTAINS %@", sunday.formatted(.dateTime.weekday(.wide).month(.wide).day()))).firstMatch
            XCTAssertTrue(sundayChoice.waitForExistence(timeout: 5))
            sundayChoice.tap()
            app.segmentedControls["agenda-mode"].buttons["3 Days"].tap()
            XCTAssertTrue(marshall.waitForExistence(timeout: 5))
            XCTAssertEqual(marshall.value as? String, "All day")
            XCTAssertEqual(tomales.value as? String, "All day")
            capture(app, "agenda-overlapping-stays-last-day-open-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testDayBlockingAndCalendarControlsAtLargeText() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            for (textSize, accessibilityText) in [("xxxl", false), ("accessibility-xl", true)] {
                let app = launch(appearance: appearance, tab: "settings", largeText: true, accessibilityText: accessibilityText)
                waitForText("Save and sync", in: app)
                let lastCalendar = app.switches["calendar-blocks-scheduling-demo-colleague"]
                for _ in 0..<24 where !(lastCalendar.exists && lastCalendar.isHittable) {
                    app.swipeUp()
                }
                XCTAssertEqual(lastCalendar.value as? String, "1")
                tapSwitch(lastCalendar, in: app)
                XCTAssertEqual(lastCalendar.value as? String, "0")
                tapSwitch(lastCalendar, in: app)
                XCTAssertEqual(lastCalendar.value as? String, "1")
                XCTAssertLessThan(lastCalendar.frame.maxY, app.tabBars.firstMatch.frame.minY)
                capture(app, "settings-last-calendar-accessibility-\(textSize)-\(appearance)")
                let lastSetting = app.staticTexts["settings-server-host"]
                for _ in 0..<24 where !(lastSetting.exists && lastSetting.isHittable)
                    || lastSetting.frame.maxY > app.tabBars.firstMatch.frame.minY - 8 {
                    app.swipeUp()
                }
                XCTAssertTrue(lastSetting.isHittable)
                XCTAssertLessThanOrEqual(lastSetting.frame.maxY, app.tabBars.firstMatch.frame.minY - 8)
                capture(app, "settings-bottom-clearance-accessibility-\(textSize)-\(appearance)")
                app.tabBars.buttons["Agenda"].tap()
                let status = app.buttons["agenda-day-kind"]
                XCTAssertTrue(status.waitForExistence(timeout: 10))
                for control in [app.buttons["Go to day"], app.buttons["agenda-add"], app.buttons["agenda-calendars"],
                                app.buttons["Today"], status, app.segmentedControls["agenda-mode"]] {
                    XCTAssertTrue(control.isHittable)
                    XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
                    XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
                    XCTAssertLessThan(control.frame.maxY, app.tabBars.firstMatch.frame.minY)
                }
                capture(app, "agenda-header-accessibility-\(textSize)-\(appearance)")
                status.tap()
                let indicator = app.buttons.matching(NSPredicate(
                    format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "day-blocking-", "-demo-event-holiday")).firstMatch
                XCTAssertTrue(indicator.waitForExistence(timeout: 10))
                indicator.tap()
                let choice = app.buttons["event-blocks-day-demo-event-holiday"]
                for _ in 0..<6 where !(choice.exists && choice.isHittable) {
                    app.swipeUp()
                }
                XCTAssertTrue(choice.isHittable)
                XCTAssertEqual(choice.value as? String, "Automatic")
                choice.tap()
                let informational = app.buttons["Does not block"]
                XCTAssertTrue(informational.waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["Automatic"].exists)
                XCTAssertTrue(app.buttons["Blocks"].exists)
                capture(app, "day-blocking-accessibility-menu-\(textSize)-\(appearance)")
                app.buttons["Blocks"].tap()
                XCTAssertTrue(informational.waitForNonExistence(timeout: 5))
                wait(for: [
                    expectation(for: NSPredicate(format: "value == %@", "Blocks"), evaluatedWith: choice),
                    expectation(for: NSPredicate(format: "label == %@", "Blocks your day"),
                                evaluatedWith: app.staticTexts["event-blocks-day-effective-demo-event-holiday"]),
                ], timeout: 5)
                XCTAssertEqual(choice.value as? String, "Blocks")
                XCTAssertEqual(app.staticTexts["event-blocks-day-effective-demo-event-holiday"].label, "Blocks your day")
                choice.tap()
                XCTAssertTrue(informational.waitForExistence(timeout: 5))
                informational.tap()
                XCTAssertTrue(informational.waitForNonExistence(timeout: 5))
                wait(for: [
                    expectation(for: NSPredicate(format: "value == %@", "Does not block"), evaluatedWith: choice),
                    expectation(for: NSPredicate(format: "label == %@", "Does not block scheduling"),
                                evaluatedWith: app.staticTexts["event-blocks-day-effective-demo-event-holiday"]),
                ], timeout: 5)
                XCTAssertEqual(choice.value as? String, "Does not block")
                XCTAssertEqual(app.staticTexts["event-blocks-day-effective-demo-event-holiday"].label, "Does not block scheduling")
                choice.tap()
                let automatic = app.buttons["Automatic"]
                XCTAssertTrue(automatic.waitForExistence(timeout: 5))
                automatic.tap()
                XCTAssertTrue(automatic.waitForNonExistence(timeout: 5))
                wait(for: [
                    expectation(for: NSPredicate(format: "value == %@", "Automatic"), evaluatedWith: choice),
                    expectation(for: NSPredicate(format: "label == %@", "Blocks your day"),
                                evaluatedWith: app.staticTexts["event-blocks-day-effective-demo-event-holiday"]),
                ], timeout: 5)
                XCTAssertEqual(choice.value as? String, "Automatic")
                XCTAssertEqual(app.staticTexts["event-blocks-day-effective-demo-event-holiday"].label, "Blocks your day")
                capture(app, "day-blocking-accessibility-restored-\(textSize)-\(appearance)")
                app.terminate()
            }
        }
    }

    @MainActor
    func testEventDayBlockingOverrides() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, tab: "settings")
            waitForText("Save and sync", in: app)
            let showBirthdays = app.switches["calendar-selected-demo-cal-birthdays"]
            for _ in 0..<12 where !(showBirthdays.exists && showBirthdays.isHittable) {
                app.swipeUp()
            }
            XCTAssertTrue(showBirthdays.isEnabled)
            XCTAssertEqual(showBirthdays.value as? String, "0")
            tapSwitch(showBirthdays, in: app)
            app.tabBars.buttons["Agenda"].tap()
            let birthday = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Mom's birthday")).firstMatch
            XCTAssertTrue(birthday.waitForExistence(timeout: 10))
            birthday.tap()
            let choice = app.descendants(matching: .any).matching(identifier: "event-blocks-day-demo-event-birthday").firstMatch
            let effective = app.staticTexts["event-blocks-day-effective-demo-event-birthday"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertTrue(choice.isEnabled)
            XCTAssertEqual(choice.value as? String, "Automatic")
            XCTAssertEqual(effective.label, "Does not block scheduling")
            XCTAssertFalse(app.navigationBars.buttons["Edit"].exists)
            choice.descendants(matching: .any)["Blocks"].tap()
            XCTAssertEqual(choice.value as? String, "Blocks")
            XCTAssertEqual(effective.label, "Blocks your day")
            capture(app, "event-day-blocking-read-only-\(appearance)")
            app.navigationBars.buttons["Done"].tap()
            app.tabBars.buttons["Settings"].tap()
            for _ in 0..<6 where !showBirthdays.isHittable { app.swipeUp() }
            tapSwitch(showBirthdays, in: app)
            XCTAssertEqual(showBirthdays.value as? String, "0")
            app.tabBars.buttons["Agenda"].tap()
            let hiddenBirthday = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "day-blocking-", "-demo-event-birthday")).firstMatch
            app.buttons["agenda-day-kind"].tap()
            XCTAssertTrue(hiddenBirthday.waitForExistence(timeout: 5))
            hiddenBirthday.tap()
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertEqual(choice.value as? String, "Blocks")
            choice.descendants(matching: .any)["Does not block"].tap()
            XCTAssertEqual(choice.value as? String, "Does not block")
            XCTAssertEqual(effective.label, "Does not block scheduling")
            choice.descendants(matching: .any)["Automatic"].tap()
            XCTAssertEqual(choice.value as? String, "Automatic")
            XCTAssertTrue(app.staticTexts["event-blocking-reason-demo-event-birthday"].label.hasPrefix("Automatic:"))
            capture(app, "hidden-informational-event-reset-\(appearance)")
            choice.descendants(matching: .any)["Blocks"].tap()
            XCTAssertEqual(choice.value as? String, "Blocks")
            app.navigationBars.buttons["Done"].tap()
            app.buttons["agenda-day-kind"].tap()
            XCTAssertTrue(hiddenBirthday.waitForExistence(timeout: 5))
            hiddenBirthday.tap()
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertEqual(choice.value as? String, "Blocks")
            choice.descendants(matching: .any)["Automatic"].tap()
            XCTAssertEqual(choice.value as? String, "Automatic")
            XCTAssertEqual(effective.label, "Does not block scheduling")
            XCTAssertTrue(app.staticTexts["event-blocking-reason-demo-event-birthday"].label.hasPrefix("Automatic:"))
            capture(app, "reopened-hidden-event-reset-\(appearance)")
            app.navigationBars.buttons["Done"].tap()

            let ooo = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Marcus out of office")).firstMatch
            ooo.tap()
            let oooChoice = app.descendants(matching: .any).matching(identifier: "event-blocks-day-demo-event-ooo").firstMatch
            let oooEffective = app.staticTexts["event-blocks-day-effective-demo-event-ooo"]
            XCTAssertTrue(oooChoice.waitForExistence(timeout: 5))
            XCTAssertEqual(oooChoice.value as? String, "Automatic")
            XCTAssertEqual(oooEffective.label, "Does not block scheduling")
            XCTAssertTrue(app.staticTexts["event-blocking-reason-demo-event-ooo"].label.contains("A teammate is out of office"))
            oooChoice.descendants(matching: .any)["Blocks"].tap()
            XCTAssertEqual(oooEffective.label, "Blocks your day")
            oooChoice.descendants(matching: .any)["Does not block"].tap()
            XCTAssertEqual(oooEffective.label, "Does not block scheduling")
            capture(app, "event-day-blocking-ooo-override-\(appearance)")
            oooChoice.descendants(matching: .any)["Automatic"].tap()
            XCTAssertEqual(oooEffective.label, "Does not block scheduling")
            app.terminate()

            let timed = launch(appearance: appearance, sheet: "event")
            waitForText("Design review: scheduler v2", in: timed)
            XCTAssertFalse(timed.descendants(matching: .any)["event-blocks-day-demo-event-design"].exists)
            timed.terminate()
        }
    }

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
            XCTAssertTrue(app.textFields["event-quick-add-input"].waitForExistence(timeout: 5))
            app.buttons["event-quick-add-details"].tap()
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
        let demoNow = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 10))!
        let today = calendar.startOfDay(for: demoNow)
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, mode: "threeDays", demoNow: demoNow)
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
            let taskBlock = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Rotate AWS access keys")).firstMatch
            positionInGrid(taskBlock, in: app)
            let beforeVerticalScroll = taskBlock.frame.minY
            let gutter = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.7))
            gutter.press(forDuration: 0.05, thenDragTo: gutter.withOffset(CGVector(dx: 0, dy: -80)),
                         withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertLessThan(taskBlock.frame.minY, beforeVerticalScroll - 50)
            let originalY = taskBlock.frame.minY
            right.press(forDuration: 0.05, thenDragTo: right.withOffset(CGVector(dx: -oneColumn, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 1)
            // Yesterday's block is behind the fixed gutter, not an invisible tap target there.
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 25, dy: originalY + 10)).tap()
            XCTAssertFalse(app.buttons["Cancel"].exists)
            left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: oneColumn, dy: 0)),
                       withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 1)
            right.tap()
            XCTAssertTrue(app.textFields["event-quick-add-input"].waitForExistence(timeout: 5))
            app.buttons["event-quick-add-details"].tap()
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
            XCTAssertEqual(taskBlock.frame.minY, originalY, accuracy: 2, "Horizontal movement must retain the hour position")
            capture(app, "three-day-before-tap-\(appearance)")
            taskBlock.tap()
            XCTAssertTrue(app.buttons["Mark done"].waitForExistence(timeout: 5))
            app.buttons["Cancel"].tap()
            XCTAssertEqual(taskBlock.frame.minY, originalY, accuracy: 2, "Opening an editor must not change the measured viewport")
            capture(app, "three-day-after-tap-\(appearance)")
            let start = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: today)!
            moveHalfHour(taskBlock, from: start, in: app)
            capture(app, "three-day-after-drag-\(appearance)")
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
            XCTAssertTrue(taskBlock.isHittable)
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
            XCTAssertTrue(taskBlock.isHittable)
            // The single-day control still pages by one day, then re-enters the carousel there.
            app.segmentedControls["agenda-mode"].buttons["Day"].tap()
            right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0.3)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            XCTAssertEqual(heading.value as? String, tomorrow.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
            app.segmentedControls["agenda-mode"].buttons["3 Days"].tap()
            XCTAssertTrue(app.buttons["Architecture sync"].exists)
            app.buttons["Today"].tap()
            XCTAssertTrue(taskBlock.isHittable)
            app.terminate()
        }
    }

    @MainActor
    func testHalfHourDragAtDemoTimes() {
        continueAfterFailure = false
        let calendar = Calendar.current
        let clocks = [(0, 10), (18, 0), (23, 50)].map { hour, minute in
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: hour, minute: minute))!
        }
        for clock in clocks {
            for appearance in ["light", "dark"] {
                let scenario = "\(ISO8601DateFormatter().string(from: clock))-\(appearance)"
                XCTContext.runActivity(named: scenario) { _ in
                    let app = launch(appearance: appearance, mode: "threeDays", demoNow: clock)
                    waitForText("Infra offsite", in: app)
                    let heading = app.buttons["Go to day"]
                    XCTAssertEqual(heading.value as? String,
                                   clock.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    let taskBlock = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Rotate AWS access keys")).firstMatch
                    positionInGrid(taskBlock, in: app)
                    let originalY = taskBlock.frame.minY
                    capture(app, "before-tap-\(scenario)")
                    taskBlock.tap()
                    XCTAssertTrue(app.buttons["Mark done"].waitForExistence(timeout: 5))
                    app.buttons["Cancel"].tap()
                    XCTAssertEqual(taskBlock.frame.minY, originalY, accuracy: 2,
                                   "Opening an editor must not change the measured viewport")
                    capture(app, "after-tap-\(scenario)")
                    let start = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: clock)!
                    moveHalfHour(taskBlock, from: start, in: app)
                    moveHalfHour(taskBlock, from: start.addingTimeInterval(30 * 60), in: app)
                    capture(app, "after-two-drags-\(scenario)")
                    app.terminate()
                }
            }
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
            XCTAssertTrue(app.buttons["quick-add-save"].exists)
            capture(app, "widget-add-task-\(appearance)")
            app.buttons["Cancel"].tap()
            app.open(URL(string: "florida://agenda")!)
            app.buttons["agenda-add"].tap()
            app.buttons["New Event"].tap()
            XCTAssertTrue(app.textFields["event-quick-add-input"].waitForExistence(timeout: 5))
            app.buttons["event-quick-add-details"].tap()
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
            let planning = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Weekly planning")).firstMatch
            for _ in 0..<8 where !planning.exists { app.swipeUp() }
            waitForText("Weekly planning", in: app)
            capture(app, "event-recurring-saved-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testUnifiedTaskCapture() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, tab: "tasks")
            waitForText("Renew VPN certificate", in: app)
            // The widget URL opens the same keyboard-ready composer as the in-app controls.
            app.terminate()
            app.open(URL(string: "florida://tasks/new")!)
            let input = element("quick-add-input", in: app)
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            // Fresh simulators can show the system swipe-typing introduction over the keyboard.
            if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
            XCTAssertFalse(app.buttons["quick-add-save"].isEnabled)
            capture(app, "capture-empty-\(appearance)")
            input.typeText("Send security update 45m tomorrow #work #q4")
            XCTAssertFalse(app.buttons["quick-add-save"].isEnabled, "#work must not silently pick one of two categories")
            XCTAssertTrue(app.buttons["quick-add-category-demo-eng"].exists)
            XCTAssertTrue(app.buttons["quick-add-category-demo-infosec"].exists)
            capture(app, "capture-categories-\(appearance)")
            app.buttons["quick-add-category-demo-infosec"].tap()
            XCTAssertTrue(app.buttons["quick-add-category"].label.contains("Work Infosec"), app.buttons["quick-add-category"].debugDescription)
            XCTAssertEqual(app.staticTexts["quick-add-title"].label, "Send security update #q4", "Later hashtags stay literal after resolving the first")
            XCTAssertTrue(app.buttons["quick-add-save"].isEnabled)
            capture(app, "capture-ready-\(appearance)")
            app.buttons["Cancel"].tap()
            app.tabBars.buttons["Agenda"].tap()
            app.buttons["agenda-add"].tap()
            app.buttons["New Task"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertEqual(input.value as? String, "Send security update 45m tomorrow #work #q4")
            XCTAssertTrue(app.buttons["quick-add-category"].label.contains("Work Infosec"))
            app.buttons["Details"].tap()
            XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["Title"].value as? String, "Send security update #q4")
            XCTAssertTrue(app.buttons["task-category"].label.contains("Work Infosec"))
            app.buttons["task-editor-cancel"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertEqual(input.value as? String, "Send security update 45m tomorrow #work #q4")
            if appearance == "dark" {
                input.typeText("\n")
            } else {
                app.buttons["quick-add-save"].tap()
            }
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            app.tabBars.buttons["Tasks"].tap()
            let filed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send security update"))
            positionInTaskList(filed.firstMatch, in: app)
            XCTAssertTrue(filed.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(filed.count, 1)
            filed.firstMatch.tap()
            XCTAssertTrue(app.buttons["task-category"].label.contains("Work Infosec"), "Categorized capture must skip Inbox")
            app.buttons["Cancel"].tap()

            // The Tasks toolbar is the same route. No hint means Inbox; Details saves once
            // and consumes the draft just like the primary Add button.
            app.buttons["New task"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["quick-add-save"].isEnabled)
            input.typeText("Remember umbrella")
            XCTAssertTrue(app.buttons["quick-add-category"].label.contains("Inbox"))
            app.buttons["Details"].tap()
            XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
            app.buttons["Add"].tap()
            XCTAssertTrue(app.navigationBars["New Task"].waitForNonExistence(timeout: 5))
            let unfiled = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remember umbrella"))
            positionInTaskList(unfiled.firstMatch, in: app, towardEnd: false)
            XCTAssertTrue(unfiled.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(unfiled.count, 1)
            unfiled.firstMatch.tap()
            XCTAssertTrue(app.buttons["task-category"].label.contains("Inbox"))
            revealTaskEditorControl(app.buttons["task-category"], in: app)
            app.buttons["task-category"].tap()
            XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5))
            wait(for: [expectation(for: NSPredicate(format: "isHittable == true"),
                                   evaluatedWith: app.buttons["Home"])], timeout: 5)
            XCTAssertTrue(app.buttons["Home"].isHittable)
            app.buttons["Home"].tap()
            wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "Home"),
                                   evaluatedWith: app.buttons["task-category"])], timeout: 5)
            XCTAssertTrue(app.buttons["Home"].waitForNonExistence(timeout: 5))
            let save = app.navigationBars["Edit Task"].buttons["Save"]
            XCTAssertTrue(save.isHittable)
            save.tap()
            XCTAssertTrue(app.navigationBars["Edit Task"].waitForNonExistence(timeout: 5))
            // A row partly behind the floating tab bar can report hittable, but its center
            // taps the bar instead. Bring the whole row into the visible list before opening it.
            positionInTaskList(unfiled.firstMatch, in: app)
            unfiled.firstMatch.tap()
            XCTAssertTrue(app.buttons["task-category"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["task-category"].label.contains("Home"), "Filing moves the task out of Inbox")
            app.buttons["Cancel"].tap()
            if appearance == "light" {
                app.buttons["New task"].tap()
                XCTAssertTrue(input.waitForExistence(timeout: 5))
                input.typeText("Plan cabin trip #weekend")
                XCTAssertFalse(app.buttons["quick-add-save"].isEnabled)
                capture(app, "capture-new-category")
                app.buttons["Create “Weekend”"].tap()
                XCTAssertTrue(app.buttons["quick-add-category"].label.contains("Weekend"))
                app.buttons["Details"].tap()
                XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.textFields["Title"].value as? String, "Plan cabin trip")
                XCTAssertTrue(app.buttons["task-category"].label.contains("Weekend"))
                app.buttons["Add"].tap()
                XCTAssertTrue(app.navigationBars["New Task"].waitForNonExistence(timeout: 5))
            }
            app.terminate()
        }
    }

    @MainActor
    func testCapturePasteAndDeletedCategory() {
        continueAfterFailure = false
        let app = launch(tab: "tasks")
        waitForText("Renew VPN certificate", in: app)
        app.buttons["New task"].tap()
        let input = app.textViews["quick-add-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("Read report")
        app.buttons["quick-add-category"].tap()
        app.buttons["Home"].tap()
        input.typeText(" #")
        XCTAssertFalse(app.buttons["quick-add-save"].isEnabled)
        app.buttons["quick-add-category-demo-home"].tap()
        XCTAssertEqual(input.value as? String, "Read report", "A bare # opens all categories even after a prior choice")
        // The net edit is just a newline, but a real clipboard paste must never submit.
        UIPasteboard.general.string = "Read report\n"
        input.press(forDuration: 1)
        app.menuItems["Select All"].tap()
        app.menuItems["Paste"].tap()
        if app.buttons["Allow Paste"].waitForExistence(timeout: 2) { app.buttons["Allow Paste"].tap() }
        XCTAssertTrue(input.exists)
        XCTAssertEqual(input.value as? String, "Read report\n")
        XCTAssertEqual(app.staticTexts["quick-add-title"].label, "Read report")
        UIPasteboard.general.string = "\n"
        input.tap()
        input.press(forDuration: 1)
        app.menuItems["Paste"].tap()
        XCTAssertTrue(input.exists, "Pasting a newline is not the Done key either")
        XCTAssertEqual(input.value as? String, "Read report\n\n")
        app.buttons["Cancel"].tap()

        app.buttons["Categories"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home")).firstMatch.tap()
        app.buttons["Delete Category"].tap()
        app.sheets.buttons["Delete Category"].tap()
        XCTAssertTrue(app.navigationBars["Edit Category"].waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["New task"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Read report\n\n")
        XCTAssertFalse(app.buttons["quick-add-save"].isEnabled, "A deleted destination cannot be used by a retained draft")
        XCTAssertFalse(app.buttons["Details"].isEnabled)
        XCTAssertTrue(app.buttons["quick-add-category"].label.contains("Choose a category"))
        app.buttons["quick-add-category"].tap()
        app.buttons["Inbox"].tap()
        input.typeText("\n")
        XCTAssertTrue(input.waitForNonExistence(timeout: 5), "Done still submits after a multiline paste")
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read report"))
        XCTAssertTrue(saved.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(saved.count, 1)
        app.terminate()
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
        large.buttons["New task"].tap()
        let input = large.textViews["quick-add-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("Read report #home")
        XCTAssertTrue(large.buttons["Details"].isHittable)
        XCTAssertTrue(large.buttons["quick-add-save"].isHittable)
        capture(large, "capture-large-text")
        large.buttons["quick-add-save"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
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
            waitForText("Renew VPN certificate", in: tasks)
            let row = tasks.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fix flaky scheduler test")).firstMatch
            positionInTaskList(row, in: tasks)
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
            let form = app.collectionViews["task-editor-form"]
            let addStart = form.buttons.matching(NSPredicate(format: "identifier == %@", "task-start-add")).element
            XCTAssertTrue(addStart.waitForExistence(timeout: 20))
            addStart.tap()
            XCTAssertTrue(form.datePickers.matching(NSPredicate(format: "identifier == %@", "task-start-date")).element.waitForExistence(timeout: 5))
            capture(app, "task-editor-start-added-\(appearance)")

            form.buttons.matching(NSPredicate(format: "identifier == %@", "task-category")).element.tap()
            XCTAssertTrue(app.buttons["Personal Finance"].waitForExistence(timeout: 5))
            capture(app, "task-category-picker-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func element(startingWith prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    func testCalendarVisibilityAndBlockingAreIndependent() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, tab: "settings")
            waitForText("Save and sync", in: app)
            let visible = app.switches["calendar-selected-demo-cal-ooo"]
            let blocking = app.switches["calendar-blocks-scheduling-demo-cal-ooo"]
            let account = app.staticTexts["calendar-account-header-demo-personal"]
            let firstCalendar = app.staticTexts["calendar-name-demo-family"]
            for _ in 0..<12 where !(account.exists && account.isHittable && firstCalendar.exists && firstCalendar.isHittable) {
                app.swipeUp()
            }
            XCTAssertTrue(account.isHittable)
            XCTAssertTrue(firstCalendar.isHittable)
            let gap = firstCalendar.frame.minY - account.frame.maxY
            XCTAssertGreaterThanOrEqual(gap, 0)
            XCTAssertLessThanOrEqual(gap, 50, "The account header should sit directly above its calendars")
            capture(app, "calendar-account-spacing-iphone-\(appearance)")
            for _ in 0..<12 where !(blocking.exists && blocking.isHittable) {
                app.swipeUp()
            }
            XCTAssertTrue(visible.isHittable)
            XCTAssertTrue(blocking.isHittable)
            XCTAssertTrue(visible.isEnabled)
            XCTAssertTrue(blocking.isEnabled)
            XCTAssertEqual(visible.value as? String, "1")
            XCTAssertEqual(blocking.value as? String, "1")

            tapSwitch(blocking, in: app)
            XCTAssertEqual(blocking.value as? String, "0")
            XCTAssertEqual(visible.value as? String, "1")
            app.tabBars.buttons["Agenda"].tap()
            waitForText("Marcus out of office", in: app)
            app.tabBars.buttons["Settings"].tap()

            tapSwitch(visible, in: app)
            XCTAssertEqual(visible.value as? String, "0")
            XCTAssertEqual(blocking.value as? String, "0")
            tapSwitch(blocking, in: app)
            XCTAssertEqual(blocking.value as? String, "1")
            XCTAssertEqual(visible.value as? String, "0")
            capture(app, "calendar-hidden-blocking-\(appearance)")
            app.tabBars.buttons["Agenda"].tap()
            let event = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Marcus out of office")).firstMatch
            XCTAssertTrue(event.waitForNonExistence(timeout: 5))
            app.tabBars.buttons["Settings"].tap()

            tapSwitch(blocking, in: app)
            XCTAssertEqual(blocking.value as? String, "0")
            XCTAssertEqual(visible.value as? String, "0")
            tapSwitch(visible, in: app)
            XCTAssertEqual(visible.value as? String, "1")
            XCTAssertEqual(blocking.value as? String, "0")
            capture(app, "calendar-visible-informational-\(appearance)")
            app.tabBars.buttons["Agenda"].tap()
            waitForText("Marcus out of office", in: app)
            app.terminate()
        }
    }

    @MainActor
    private func tapSwitch(_ control: XCUIElement, in app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        let top = app.navigationBars.firstMatch.frame.maxY + 8
        let bottom = tabBar.frame.minY - 8
        let middle = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.midX, dy: (top + bottom) / 2))
        for _ in 0..<20 {
            var travel: CGFloat = -160
            if control.exists {
                let frame = control.frame
                if !frame.isEmpty, [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) {
                    if frame.minY >= top, frame.maxY <= bottom { break }
                    let distance = frame.minY < top ? top - frame.minY : bottom - frame.maxY
                    travel = distance > 0 ? min(160, max(24, distance)) : max(-160, min(-24, distance))
                }
            }
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: travel)),
                         withVelocity: .slow, thenHoldForDuration: 0)
        }
        XCTAssertGreaterThanOrEqual(control.frame.minY, top)
        XCTAssertLessThanOrEqual(control.frame.maxY, tabBar.frame.minY - 8)
        let native = control.switches.firstMatch
        XCTAssertTrue(native.waitForExistence(timeout: 5))
        XCTAssertTrue(native.isHittable)
        XCTAssertGreaterThanOrEqual(native.frame.minY, top)
        XCTAssertLessThanOrEqual(native.frame.maxY, bottom)
        let previous = native.value as? String
        XCTAssertTrue(previous == "0" || previous == "1")
        native.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", previous == "1" ? "0" : "1"), object: native)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        wait(for: [expectation(for: NSPredicate(format: "value == %@", previous == "1" ? "0" : "1"),
                               evaluatedWith: control)], timeout: 5)
        XCTAssertEqual(control.value as? String, previous == "1" ? "0" : "1")
    }

    @MainActor
    private func positionInTaskList(_ task: XCUIElement, in app: XCUIApplication, towardEnd: Bool = true) {
        let top = app.navigationBars.firstMatch.frame.maxY + 8
        let bottom = app.tabBars.firstMatch.frame.minY - 8
        let middle = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.midX, dy: (top + bottom) / 2))
        for _ in 0..<20 {
            var travel: CGFloat = towardEnd ? -160 : 160
            if task.exists {
                let frame = task.frame
                if frame.height > 0 {
                    if frame.minY >= top && frame.maxY <= bottom { break }
                    let distance = frame.minY < top ? top - frame.minY : bottom - frame.maxY
                    travel = distance > 0 ? min(160, max(32, distance)) : max(-160, min(-32, distance))
                }
            }
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: travel)),
                         withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(task.exists)
        XCTAssertGreaterThanOrEqual(task.frame.minY, top)
        XCTAssertLessThanOrEqual(task.frame.maxY, bottom)
        XCTAssertTrue(task.isHittable)
    }

    @MainActor
    private func positionInGrid(_ task: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        let hours = app.scrollViews["day-grid-hours"]
        XCTAssertTrue(hours.waitForExistence(timeout: 5))
        let viewport = hours.frame.intersection(app.frame)
        let targetY = viewport.midY
        let gutter = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 26, dy: viewport.midY))
        for _ in 0..<8 {
            let distance = targetY - task.frame.minY
            if abs(distance) < 20 { break }
            let travel = min(max(distance, -viewport.height * 0.6), viewport.height * 0.6)
            gutter.press(forDuration: 0.05, thenDragTo: gutter.withOffset(CGVector(dx: 0, dy: travel)),
                         withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 0.5)
        }
        XCTAssertGreaterThan(task.frame.minY, viewport.minY + 110)
        XCTAssertLessThan(task.frame.maxY, viewport.maxY - 80)
        XCTAssertTrue(task.isHittable)
    }

    @MainActor
    private func moveHalfHour(_ task: XCUIElement, from start: Date, in app: XCUIApplication) {
        let end = start.addingTimeInterval(45 * 60)
        let expectedBefore = "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        XCTAssertEqual(task.value as? String, expectedBefore)
        let originalFrame = task.frame
        let dayHeader = element(start.formatted(.dateTime.weekday(.wide).month(.wide).day()), in: app).frame
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let nextHeader = element(nextDay.formatted(.dateTime.weekday(.wide).month(.wide).day()), in: app).frame
        let columnWidth = nextHeader.midX - dayHeader.midX
        let heading = app.buttons["Go to day"].value as? String
        let center = task.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.5, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 30)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        let newStart = start.addingTimeInterval(30 * 60)
        let newEnd = end.addingTimeInterval(30 * 60)
        let expectedAfter = "\(newStart.formatted(date: .omitted, time: .shortened)) – \(newEnd.formatted(date: .omitted, time: .shortened))"
        XCTAssertEqual(task.value as? String, expectedAfter, "The task must move exactly half an hour, preserving its duration")
        XCTAssertEqual(task.frame.minY, originalFrame.minY + 30, accuracy: 2, "The task should move by half an hour")
        XCTAssertGreaterThan(columnWidth, 0)
        XCTAssertGreaterThanOrEqual(task.frame.minX, dayHeader.midX - columnWidth / 2)
        XCTAssertLessThanOrEqual(task.frame.maxX, dayHeader.midX + columnWidth / 2,
                                 "A vertical drag must keep the task in its day column")
        XCTAssertEqual(app.buttons["Go to day"].value as? String, heading)
    }

    @MainActor
    private func launch(
        appearance: String = "light", tab: String = "agenda", sheet: String? = nil, mode: String = "list", largeText: Bool = false,
        recordResourceOpens: Bool = false, recordSourceOpens: Bool = false, demoNow: Date? = nil, accessibilityText: Bool = false,
        overlappingStays: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        // The agenda mode is always passed: the app remembers the last one in the App Group
        // defaults, which the simulator keeps between the launches of one test run.
        app.launchArguments = ["-demoData", "YES", "-uiTab", tab, "-uiAppearance", appearance, "-uiAgendaMode", mode]
        if let sheet { app.launchArguments += ["-uiSheet", sheet] }
        if recordResourceOpens { app.launchArguments += ["-uiRecordResourceOpens", "YES"] }
        if let demoNow { app.launchArguments += ["-demoNow", ISO8601DateFormatter().string(from: demoNow)] }
        if recordSourceOpens { app.launchArguments += ["-uiRecordSourceOpens", "YES"] }
        if overlappingStays { app.launchArguments += ["-uiOverlappingStaysDemo", "YES"] }
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            accessibilityText ? "UICTContentSizeCategoryAccessibilityXL"
                : largeText ? "UICTContentSizeCategoryXXXL" : "UICTContentSizeCategoryL",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, in app: XCUIApplication) {
        field.tap()
        field.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        field.typeText(text)
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
