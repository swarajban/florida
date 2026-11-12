import XCTest

/// Exercise the real window and keyboard route, not a second implementation of the screens.
/// Kept screenshots are exported from the result bundle by CI for light/dark visual review.
final class SmokeTests: XCTestCase {
    @MainActor
    func testEventResourcesInBothAppearances() throws {
        continueAfterFailure = false
        let resourceURLs = [
            "https://docs.google.com/document/d/demo-scheduler/edit",
            "https://docs.google.com/spreadsheets/d/demo-capacity/edit",
            "https://docs.google.com/presentation/d/demo-review/edit",
            "https://www.notion.so/demo/decisions",
            "https://www.figma.com/design/demo/calendar",
            "https://github.com/example/florida/pull/42",
            "https://linear.app/demo/issue/DEMO-21",
            "https://notes.example.com/design-review",
            "https://zoom.us/j/123456789",
            "https://meet.google.com/alt-room-xyz",
            "https://wiki.example.com/scheduler",
        ]
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance, "-uiRecordResourceOpens", "YES"]
            app.launch()
            defer { app.terminate() }
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 10))

            app.typeKey("/", modifierFlags: [])
            let input = app.textFields.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("Design review: scheduler v2")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            app.typeKey(.return, modifierFlags: [])
            let edit = app.buttons["Edit…"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            let document = app.buttons["event-resource-https://docs.google.com/document/d/demo-scheduler/edit"]
            XCTAssertTrue(document.waitForExistence(timeout: 5))
            XCTAssertEqual(document.label, "Scheduler v2 RFC, Google Docs")
            XCTAssertTrue(app.buttons["Resources"].exists)
            XCTAssertFalse(app.buttons["event-resource-https://meet.google.com/abc-defg-hij"].exists)
            capture(app.popovers.firstMatch, "event-resources-\(appearance)")
            document.click()
            XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Opened resource: https://docs.google.com/document/d/demo-scheduler/edit"].exists)

            app.typeKey("f", modifierFlags: [])
            let label = app.staticTexts["event-jump-demo-event-offsite"]
            XCTAssertTrue(label.waitForExistence(timeout: 5))
            let keys = try XCTUnwrap(label.value as? String).lowercased()
            XCTAssertFalse(keys.isEmpty)
            for key in keys { app.typeKey(String(key), modifierFlags: []) }
            XCTAssertTrue(document.waitForExistence(timeout: 5))
            let resourceKeys = try XCTUnwrap(document.value as? String)
            XCTAssertFalse(resourceKeys.isEmpty)
            XCTAssertTrue(resourceKeys.allSatisfy(\.isNumber))
            for key in resourceKeys { app.typeKey(String(key), modifierFlags: []) }
            XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Opened resource: https://docs.google.com/document/d/demo-scheduler/edit"].exists)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(document.waitForExistence(timeout: 5))
            let shelf = app.scrollViews["event-resource-shelf"]
            let runbook = app.buttons["event-resource-https://wiki.example.com/scheduler"]
            let unexpectedTiles = shelf.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND NOT (identifier IN %@)",
                argumentArray: ["event-resource-", resourceURLs.map { "event-resource-\($0)" }]))
            XCTAssertEqual(unexpectedTiles.count, 0)
            var shortcuts = Set<String>()
            for url in resourceURLs {
                let tile = shelf.buttons["event-resource-\(url)"]
                for _ in 0..<4 where !tile.isHittable {
                    shelf.scroll(byDeltaX: 0, deltaY: -80)
                    XCTAssertEqual(unexpectedTiles.count, 0)
                }
                XCTAssertTrue(tile.waitForExistence(timeout: 5), url)
                XCTAssertTrue(tile.isHittable, url)
                let shortcut = try XCTUnwrap(tile.value as? String, url)
                XCTAssertFalse(shortcut.isEmpty, url)
                XCTAssertTrue(shortcut.allSatisfy(\.isNumber), url)
                XCTAssertTrue(shortcuts.insert(shortcut).inserted, url)
                XCTAssertEqual(unexpectedTiles.count, 0)
            }
            XCTAssertTrue(runbook.isHittable)
            XCTAssertEqual(shortcuts.count, 11)
            for key in shortcuts {
                XCTAssertFalse(shortcuts.contains { $0 != key && $0.hasPrefix(key) })
            }
            let runbookKeys = try XCTUnwrap(runbook.value as? String)
            XCTAssertEqual(runbookKeys.count, 2)
            capture(app.popovers.firstMatch, "event-resource-two-digit-\(appearance)")
            for key in runbookKeys { app.typeKey(String(key), modifierFlags: []) }
            XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Opened resource: https://wiki.example.com/scheduler"].exists)
            XCTAssertEqual((app.radioButtons["3 Days"].value as? NSNumber)?.intValue, 1)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(document.waitForExistence(timeout: 5))
            app.typeKey("g", modifierFlags: [])
            app.typeKey("r", modifierFlags: [])
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Capacity model"].exists)
            XCTAssertTrue(app.staticTexts["Scheduler follow-up"].exists)
            capture(window, "event-resource-picker-\(appearance)")
            app.typeKey(.downArrow, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Opened resource: https://docs.google.com/spreadsheets/d/demo-capacity/edit"].exists)

            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("Open event resources")
            XCTAssertTrue(app.staticTexts["Open event resources"].exists)
            app.typeKey(.return, modifierFlags: [])
            let resources = app.textFields["Open an event resource…"]
            XCTAssertTrue(resources.waitForExistence(timeout: 5))
            resources.typeText("Scheduler follow-up")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(resources.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Opened resource: https://linear.app/demo/issue/DEMO-21"].exists)

            app.typeKey("/", modifierFlags: [])
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("Lunch with Priya")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Resources"].exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
            app.typeKey("g", modifierFlags: [])
            app.typeKey("r", modifierFlags: [])
            XCTAssertTrue(app.staticTexts["This event has no resources"].exists)
        }
    }

    @MainActor
    func testEventDayBlockingOverrides() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
            app.typeKey(",", modifierFlags: .command)
            let calendars = app.toolbars.buttons["Calendars"]
            XCTAssertTrue(calendars.waitForExistence(timeout: 5))
            calendars.click()
            let showBirthdays = app.checkBoxes["calendar-selected-demo-cal-birthdays"]
            XCTAssertTrue(showBirthdays.waitForExistence(timeout: 5))
            XCTAssertTrue(showBirthdays.isEnabled)
            XCTAssertEqual((showBirthdays.value as? NSNumber)?.boolValue, false)
            showBirthdays.click()
            app.typeKey("w", modifierFlags: .command)

            app.typeKey("k", modifierFlags: .command)
            let palette = app.textFields.firstMatch
            XCTAssertTrue(palette.waitForExistence(timeout: 5))
            palette.typeText("Cycle day blocking")
            XCTAssertTrue(app.staticTexts["Cycle day blocking"].exists)
            app.typeKey(.escape, modifierFlags: [])

            app.typeKey("f", modifierFlags: [])
            let birthday = app.staticTexts["event-jump-demo-event-birthday"]
            XCTAssertTrue(birthday.waitForExistence(timeout: 5))
            let keys = try XCTUnwrap(birthday.value as? String).lowercased()
            for key in keys { app.typeKey(String(key), modifierFlags: []) }
            let choice = app.popUpButtons["event-blocks-day-demo-event-birthday"]
            let effective = app.staticTexts["event-blocks-day-effective-demo-event-birthday"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertTrue(choice.isEnabled)
            XCTAssertEqual(choice.value as? String, "Automatic")
            XCTAssertEqual(effective.value as? String, "Does not block scheduling")
            XCTAssertFalse(app.buttons["Edit…"].exists)
            for expected in ["Blocks", "Does not block", "Automatic"] {
                app.typeKey("r", modifierFlags: [])
                app.typeKey("b", modifierFlags: [])
                XCTAssertEqual(choice.value as? String, expected)
            }
            choice.click()
            app.menuItems["Blocks"].click()
            XCTAssertEqual(effective.value as? String, "Blocks your day")
            capture(app, "event-day-blocking-read-only-mac-\(appearance)")
            choice.click()
            app.menuItems["Automatic"].click()
            app.typeKey(.escape, modifierFlags: [])

            app.typeKey("f", modifierFlags: [])
            let ooo = app.staticTexts["event-jump-demo-event-ooo"]
            XCTAssertTrue(ooo.waitForExistence(timeout: 5))
            let oooKeys = try XCTUnwrap(ooo.value as? String).lowercased()
            for key in oooKeys { app.typeKey(String(key), modifierFlags: []) }
            let oooChoice = app.popUpButtons["event-blocks-day-demo-event-ooo"]
            let oooEffective = app.staticTexts["event-blocks-day-effective-demo-event-ooo"]
            XCTAssertTrue(oooChoice.waitForExistence(timeout: 5))
            XCTAssertEqual(oooChoice.value as? String, "Automatic")
            XCTAssertEqual(oooEffective.value as? String, "Blocks your day")
            oooChoice.click()
            app.menuItems["Does not block"].click()
            XCTAssertEqual(oooEffective.value as? String, "Does not block scheduling")
            capture(app, "event-day-blocking-ooo-override-mac-\(appearance)")
            oooChoice.click()
            app.menuItems["Automatic"].click()
            XCTAssertEqual(oooEffective.value as? String, "Blocks your day")
            app.terminate()
        }
    }

    @MainActor
    func testCalendarVisibilityAndBlockingAreIndependent() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
            app.typeKey(",", modifierFlags: .command)
            let calendars = app.toolbars.buttons["Calendars"]
            XCTAssertTrue(calendars.waitForExistence(timeout: 5))
            calendars.click()
            let visible = app.checkBoxes["calendar-selected-demo-cal-ooo"]
            let blocking = app.checkBoxes["calendar-blocks-scheduling-demo-cal-ooo"]
            let account = app.staticTexts["calendar-account-header-demo-personal"]
            let firstCalendar = app.staticTexts["calendar-name-demo-family"]
            XCTAssertTrue(firstCalendar.waitForExistence(timeout: 5))
            XCTAssertTrue(account.isHittable)
            XCTAssertTrue(firstCalendar.isHittable)
            let gap = firstCalendar.frame.minY - account.frame.maxY
            XCTAssertGreaterThanOrEqual(gap, 0)
            XCTAssertLessThanOrEqual(gap, 40, "The first account must not reserve an empty section-header band")
            capture(app.windows.firstMatch, "calendar-account-spacing-mac-\(appearance)")
            for _ in 0..<8 where !(blocking.exists && blocking.isHittable) {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                    .scroll(byDeltaX: 0, deltaY: -180)
            }
            XCTAssertTrue(visible.isHittable)
            XCTAssertTrue(blocking.isHittable)
            XCTAssertEqual((visible.value as? NSNumber)?.boolValue, true)
            XCTAssertEqual((blocking.value as? NSNumber)?.boolValue, true)

            blocking.click()
            XCTAssertEqual((blocking.value as? NSNumber)?.boolValue, false)
            XCTAssertEqual((visible.value as? NSNumber)?.boolValue, true)
            visible.click()
            XCTAssertEqual((visible.value as? NSNumber)?.boolValue, false)
            XCTAssertEqual((blocking.value as? NSNumber)?.boolValue, false)
            blocking.click()
            XCTAssertEqual((blocking.value as? NSNumber)?.boolValue, true)
            XCTAssertEqual((visible.value as? NSNumber)?.boolValue, false)
            capture(app.windows.firstMatch, "calendar-hidden-blocking-mac-\(appearance)")

            blocking.click()
            XCTAssertEqual((blocking.value as? NSNumber)?.boolValue, false)
            XCTAssertEqual((visible.value as? NSNumber)?.boolValue, false)
            visible.click()
            XCTAssertEqual((visible.value as? NSNumber)?.boolValue, true)
            XCTAssertEqual((blocking.value as? NSNumber)?.boolValue, false)
            capture(app.windows.firstMatch, "calendar-visible-informational-mac-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testCompletionStamp() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            let row = app.staticTexts["Renew VPN certificate"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
            XCTAssertTrue(app.sheets.buttons["Mark done"].waitForExistence(timeout: 5))
            app.sheets.buttons["Mark done"].click()
            XCTAssertTrue(row.waitForNonExistence(timeout: 5))
            // Center on now, where the stamp is. `z` is undo.
            app.typeKey("g", modifierFlags: [])
            app.typeKey("n", modifierFlags: [])
            let stamp = app.staticTexts["Completed: Renew VPN certificate"]
            XCTAssertTrue(stamp.waitForExistence(timeout: 5))
            XCTAssertTrue((stamp.value as? String)?.hasPrefix("Done at ") == true)
            capture(app.windows.firstMatch, "completed-at-now-mac-\(appearance)")
            app.typeKey("m", modifierFlags: .shift)
            capture(app.windows.firstMatch, "completed-month-mac-\(appearance)")
            app.typeKey("d", modifierFlags: [])
            app.typeKey("u", modifierFlags: [])
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(stamp.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testRecurringEventCreation() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
            app.typeKey("c", modifierFlags: .shift)
            let details = app.buttons["event-quick-add-details"]
            XCTAssertTrue(details.waitForExistence(timeout: 5))
            details.click()
            let title = app.sheets.textFields.firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.typeText("Weekly planning")
            let calendar = app.buttons["event-calendar"]
            XCTAssertEqual(calendar.value as? String, "demo@sempre-health.com")
            calendar.click()
            let calendarSearch = app.textFields["event-calendar-search"]
            XCTAssertTrue(calendarSearch.waitForExistence(timeout: 5))
            let choices = ["demo@sempre-health.com", "demo@personal.example", "A&S Family Calendar", "teammate@sempre-health.com"]
                .enumerated().map { index, name in
                    let choice = app.buttons["event-calendar-option-\(index)"]
                    XCTAssertTrue(choice.waitForExistence(timeout: 5))
                    XCTAssertTrue(choice.label.contains(name))
                    return choice
                }
            XCTAssertTrue(choices.allSatisfy(\.exists))
            let tops = choices.map(\.frame.minY)
            XCTAssertEqual(tops, tops.sorted())
            capture(app.windows.firstMatch, "calendar-order-\(appearance)")
            choices[0].click()
            XCTAssertTrue(calendarSearch.waitForNonExistence(timeout: 5))
            calendar.click()
            XCTAssertTrue(calendarSearch.waitForExistence(timeout: 5))
            app.typeText("personal")
            waitForValue("personal", of: calendarSearch)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(calendarSearch.waitForNonExistence(timeout: 5))
            XCTAssertEqual(calendar.value as? String, "demo@sempre-health.com")
            XCTAssertEqual(title.value as? String, "Weekly planning")
            let startTime = app.buttons["time-Starts"]
            XCTAssertTrue(startTime.exists)
            startTime.click()
            let timeSearch = app.textFields["time-Starts-search"]
            XCTAssertTrue(timeSearch.waitForExistence(timeout: 5))
            let at = Calendar.current.date(bySettingHour: 10, minute: 15, second: 0, of: Date())!
            let timeLabel = at.formatted(.dateTime.hour().minute())
            let timeOptions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'time-Starts-option-'"))
            app.typeText(at.addingTimeInterval(60).formatted(.dateTime.hour().minute()))
            XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5))
            XCTAssertEqual(timeOptions.count, 0)
            app.typeKey("a", modifierFlags: .command)
            let followingTime = at.addingTimeInterval(900).formatted(.dateTime.hour().minute())
            app.typeText(followingTime)
            XCTAssertTrue(timeOptions.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(timeOptions.firstMatch.label.contains(followingTime))
            app.typeKey("a", modifierFlags: .command)
            app.typeText(timeLabel)
            waitForValue(timeLabel, of: timeSearch)
            XCTAssertTrue(timeOptions.firstMatch.waitForExistence(timeout: 5))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(timeSearch.waitForNonExistence(timeout: 5))
            XCTAssertEqual(startTime.value as? String, timeLabel)
            let repeatPicker = app.buttons["event-repeat"]
            XCTAssertTrue(repeatPicker.exists)
            app.buttons["Cancel"].hover()
            title.hover()
            repeatPicker.hover()
            repeatPicker.click()
            let repeatSearch = app.textFields["event-repeat-search"]
            XCTAssertTrue(repeatSearch.waitForExistence(timeout: 5))
            app.typeText("Weekly")
            waitForValue("Weekly", of: repeatSearch)
            XCTAssertTrue(app.buttons["event-repeat-option-2"].waitForExistence(timeout: 5))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(repeatSearch.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Every 1 week"].waitForExistence(timeout: 5))
            app.switches["event-repeat-limit"].click()
            XCTAssertTrue(app.staticTexts["Ends after 10 occurrences"].exists)
            XCTAssertEqual((app.switches["event-repeat-limit"].value as? NSNumber)?.boolValue, true)
            app.buttons["Add Event"].hover()
            capture(app.windows.firstMatch, "event-recurring-\(appearance)")
            app.buttons["Add Event"].click()
            XCTAssertTrue(repeatPicker.waitForNonExistence(timeout: 5))
            app.typeKey("e", modifierFlags: .shift)
            let saved = app.textFields.matching(NSPredicate(format: "value == %@", "Weekly planning")).firstMatch
            XCTAssertTrue(saved.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testNaturalLanguageEventCapture() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
            app.typeKey("c", modifierFlags: .shift)
            let input = app.textFields["event-quick-add-input"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("lunch with Dana tomorrow 12-1 at Blue Bottle")
            XCTAssertTrue(app.buttons["event-quick-add-title"].exists)
            XCTAssertTrue(app.buttons["event-quick-add-date"].exists)
            XCTAssertTrue(app.buttons["event-quick-add-time"].exists)
            XCTAssertTrue(app.buttons["event-quick-add-location"].exists)
            let destination = app.descendants(matching: .any).matching(identifier: "event-quick-add-destination").firstMatch
            XCTAssertTrue(destination.waitForExistence(timeout: 5))
            XCTAssertTrue(destination.label.contains("demo@sempre-health.com"))
            capture(app.windows.firstMatch, "event-preview-\(appearance)")

            app.typeKey("6", modifierFlags: .command)
            let title = app.textFields["event-quick-add-edit-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            app.typeKey("a", modifierFlags: .command)
            title.typeText("Lunch with Dana and Lee")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))
            XCTAssertTrue(input.exists)
            app.typeKey("3", modifierFlags: .command)
            let personal = app.buttons["event-quick-add-calendar-demo-cal-personal"]
            XCTAssertTrue(personal.waitForExistence(timeout: 5))
            personal.click()
            XCTAssertTrue(personal.waitForNonExistence(timeout: 5))
            XCTAssertTrue(destination.label.contains("demo@personal.example"))
            capture(app.windows.firstMatch, "event-corrected-\(appearance)")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))

            app.typeKey("e", modifierFlags: .shift)
            let savedTitle = app.textFields["event-editor-title"]
            XCTAssertTrue(savedTitle.waitForExistence(timeout: 5))
            XCTAssertEqual(savedTitle.value as? String, "Lunch with Dana and Lee")
            XCTAssertEqual(app.popUpButtons["event-calendar"].value as? String, "demo@personal.example")
            XCTAssertEqual(app.staticTexts["event-editor-account"].label, "demo@personal.example")
            XCTAssertFalse(app.popUpButtons["event-calendar"].isEnabled)
            XCTAssertEqual(app.textFields["event-editor-location"].value as? String, "Blue Bottle")
            XCTAssertEqual((app.switches["event-editor-all-day"].value as? NSNumber)?.intValue, 0)
            XCTAssertEqual(app.popUpButtons["time-Starts"].value as? String, eventTimeLabel(hour: 12))
            XCTAssertEqual(app.popUpButtons["time-Ends"].value as? String, eventTimeLabel(hour: 13))
            XCTAssertFalse(input.exists)
            capture(app.windows.firstMatch, "event-saved-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testEventComposerFullFormPrefill() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiAppearance", "light"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
        app.typeKey("k", modifierFlags: .command)
        let palette = app.textFields.firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.typeText("New event")
        app.typeKey(.return, modifierFlags: [])
        let input = app.textFields["event-quick-add-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("Planning every tuesday 10am 45m at Blue Bottle")
        app.typeKey("e", modifierFlags: .command)
        let title = app.textFields["event-editor-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(input.exists)
        XCTAssertEqual(app.sheets.count, 1)
        XCTAssertEqual(title.value as? String, "Planning")
        XCTAssertEqual(app.textFields["event-editor-location"].value as? String, "Blue Bottle")
        XCTAssertEqual(app.popUpButtons["time-Starts"].value as? String, eventTimeLabel(hour: 10))
        XCTAssertEqual(app.popUpButtons["time-Ends"].value as? String, eventTimeLabel(hour: 10, minute: 45))
        XCTAssertEqual(app.popUpButtons["event-repeat"].value as? String, "Weekly")
        XCTAssertTrue(app.staticTexts["Every 1 week"].exists)
        XCTAssertEqual(app.popUpButtons["event-calendar"].value as? String, "demo@sempre-health.com")
        XCTAssertEqual(app.staticTexts["event-editor-account"].label, "demo@sempre-health.com")
        capture(app.windows.firstMatch, "event-full-form-prefilled")
        app.sheets.buttons["Add Event"].click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        app.typeKey("e", modifierFlags: .shift)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Planning")
    }

    @MainActor
    func testEventComposerMenuAndGridEntries() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiAppearance", "light"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["New Event…"].click()
        let input = app.textFields["event-quick-add-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("Team retreat tomorrow all day")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        app.typeKey("e", modifierFlags: .shift)
        let title = app.textFields["event-editor-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Team retreat")
        XCTAssertEqual((app.switches["event-editor-all-day"].value as? NSNumber)?.intValue, 1)
        XCTAssertFalse(app.popUpButtons["time-Starts"].exists)
        XCTAssertFalse(app.popUpButtons["time-Ends"].exists)
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
        let grid = app.descendants(matching: .any).matching(identifier: "calendar-time-grid").firstMatch
        XCTAssertTrue(grid.exists)
        let slot = grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 100, dy: 465))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(slot.screenPoint))
        slot.hover()
        slot.rightClick()
        XCTAssertTrue(app.menuItems["New Event…"].waitForExistence(timeout: 5))
        app.menuItems["New Event…"].click()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(app.popUpButtons["time-Starts"].value as? String, eventTimeLabel(hour: 7, minute: 45))
        XCTAssertEqual(app.popUpButtons["time-Ends"].value as? String, eventTimeLabel(hour: 8, minute: 15))
    }

    private func eventTimeLabel(hour: Int, minute: Int = 0) -> String {
        let at = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
        return at.formatted(.dateTime.hour().minute())
    }

    @MainActor
    func testCalendarAndQuickAddInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            defer { app.terminate() }
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 10))
            app.buttons["Today"].hover()
            capture(window, "calendar-\(appearance)")

            app.typeKey("k", modifierFlags: .command)
            let input = app.textFields.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.hover()
            input.typeText("Next day")
            XCTAssertEqual(input.value as? String, ">Next day")
            XCTAssertTrue(app.staticTexts["Next day"].exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))

            app.typeKey("c", modifierFlags: [])
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("Write launch notes 30m")
            XCTAssertTrue(app.staticTexts["Write launch notes"].exists)
            capture(window, "quick-add-\(appearance)")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Write launch notes"].waitForExistence(timeout: 5))

            // Capture month mode after the text field resigns focus.
            app.typeKey("m", modifierFlags: .shift)
            XCTAssertEqual((app.radioButtons["Month"].value as? NSNumber)?.intValue, 1)
            capture(window, "month-\(appearance)")
        }
    }

    /// Projects, the brief and the task editor, new and on an open task, each opened by its keys.
    @MainActor
    func testPlanScreensInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            defer { app.terminate() }
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["open-projects"].exists)
            XCTAssertTrue(app.buttons["open-brief"].exists)

            // The hour three projects share is after lunch: day view, scrolled to the afternoon.
            app.typeKey("d", modifierFlags: [])
            XCTAssertEqual((app.radioButtons["Day"].value as? NSNumber)?.intValue, 1)
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.7)).scroll(byDeltaX: 0, deltaY: -260)
            capture(window, "lanes-\(appearance)")

            app.typeKey("g", modifierFlags: [])
            app.typeKey("p", modifierFlags: [])
            // A project with no tasks: only the Projects sheet can show it.
            XCTAssertTrue(app.staticTexts["Home network rebuild"].waitForExistence(timeout: 5))
            capture(window, "projects-\(appearance)")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.staticTexts["Home network rebuild"].waitForNonExistence(timeout: 5))

            app.typeKey("g", modifierFlags: [])
            app.typeKey("b", modifierFlags: [])
            let headline = app.staticTexts["Keys first, then a three-project hour after lunch"]
            XCTAssertTrue(headline.waitForExistence(timeout: 5))
            capture(window, "brief-\(appearance)")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(headline.waitForNonExistence(timeout: 5))

            app.typeKey("n", modifierFlags: .shift)
            XCTAssertTrue(app.buttons["task-project"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["task-attention"].exists)
            capture(window, "task-editor-\(appearance)")
            // A new task opens unfocused, so the first Escape cancels.
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["task-project"].waitForNonExistence(timeout: 5))

            // An open task: Mark done on top, then both dates. This one was due yesterday, so
            // a start of today moves its due date to tomorrow. One click opens the row.
            let row = app.staticTexts["Renew VPN certificate"].firstMatch
            let priority = app.buttons["task-priority"]
            row.click()
            XCTAssertTrue(priority.waitForExistence(timeout: 5))
            app.buttons["task-start"].click()
            let startSearch = app.textFields["task-start-search"]
            XCTAssertTrue(startSearch.waitForExistence(timeout: 5))
            app.typeText("today")
            waitForValue("today", of: startSearch)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(startSearch.waitForNonExistence(timeout: 5))
            let today = Calendar.current.startOfDay(for: Date())
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
            XCTAssertEqual(app.buttons["task-start"].value as? String,
                           today.formatted(.dateTime.month(.abbreviated).day().year()))
            XCTAssertTrue((app.buttons["task-due"].value as? String)?.hasPrefix(
                tomorrow.formatted(.dateTime.month(.abbreviated).day().year())) == true)
            capture(window, "task-editor-open-\(appearance)")
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// The keys on an opened item. `f` and a label open a task with the keyboard in no field, so
    /// each control's key acts: `p` searches priorities, `s` chooses a start date or clears it,
    /// Space marks the task done, and `z` on the calendar brings it back. An event's popover
    /// shows its keys the same way.
    @MainActor
    func testKeysOnAnOpenedItemInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            defer { app.terminate() }
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 10))

            try typeJumpLabel(of: "demo-task-vpn", in: app)
            let priority = app.buttons["task-priority"]
            XCTAssertTrue(priority.waitForExistence(timeout: 5), "the label should open the task")
            capture(window, "task-keys-\(appearance)")

            let before = try XCTUnwrap(priority.value as? String)
            XCTAssertEqual(before, "High")
            app.typeKey("p", modifierFlags: [])
            let prioritySearch = app.textFields["task-priority-search"]
            XCTAssertTrue(prioritySearch.waitForExistence(timeout: 5))
            XCTAssertEqual(priority.value as? String, before)
            app.typeText("Low")
            waitForValue("Low", of: prioritySearch)
            XCTAssertTrue(app.buttons["task-priority-option-3"].waitForExistence(timeout: 5))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(prioritySearch.waitForNonExistence(timeout: 5))
            waitForValue("Low", of: priority)
            app.typeKey("p", modifierFlags: .shift)
            XCTAssertTrue(prioritySearch.waitForExistence(timeout: 5))
            XCTAssertEqual(priority.value as? String, "Low")
            app.typeText(before)
            waitForValue(before, of: prioritySearch)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(prioritySearch.waitForNonExistence(timeout: 5))
            waitForValue(before, of: priority)

            let start = app.buttons["task-start"]
            XCTAssertEqual(start.value as? String, "No date")
            app.typeKey("s", modifierFlags: [])
            let startSearch = app.textFields["task-start-search"]
            XCTAssertTrue(startSearch.waitForExistence(timeout: 5))
            app.typeText("today")
            waitForValue("today", of: startSearch)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(startSearch.waitForNonExistence(timeout: 5))
            let today = Calendar.current.startOfDay(for: Date())
            waitForValue(today.formatted(.dateTime.month(.abbreviated).day().year()), of: start)
            app.typeKey("s", modifierFlags: .shift)
            XCTAssertTrue(startSearch.waitForExistence(timeout: 5))
            app.typeText("none")
            waitForValue("none", of: startSearch)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(startSearch.waitForNonExistence(timeout: 5))
            waitForValue("No date", of: start)

            // Space finishes the task: the editor closes and its row leaves the pane.
            let done = app.buttons["task-done-demo-task-vpn"]
            app.typeKey(.space, modifierFlags: [])
            XCTAssertTrue(priority.waitForNonExistence(timeout: 5))
            XCTAssertTrue(done.waitForNonExistence(timeout: 5))
            app.typeKey("z", modifierFlags: [])
            XCTAssertTrue(done.waitForExistence(timeout: 5), "z should undo Mark done")

            // The grid is a canvas, so search finds the event; Return then opens its popover.
            app.typeKey("/", modifierFlags: [])
            let input = app.textFields.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("Standup")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(app.buttons["Edit…"].waitForExistence(timeout: 5))
            capture(window, "event-keys-\(appearance)")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["Edit…"].waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    func testCategorySelectorInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
            try typeJumpLabel(of: "demo-task-vpn", in: app)
            let editorTitle = app.textFields.matching(NSPredicate(format: "value == %@", "Renew VPN certificate")).firstMatch
            XCTAssertTrue(editorTitle.waitForExistence(timeout: 5))
            let category = app.buttons["task-category"]
            XCTAssertEqual(category.value as? String, "Inbox")
            let search = app.textFields["task-category-search"]
            let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-category-option-'"))

            app.typeKey("c", modifierFlags: [])
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            app.typeText("engineering")
            waitForValue("engineering", of: search)
            XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(options.count, 1)
            XCTAssertTrue(options.firstMatch.label.contains("Work Engineering"))
            XCTAssertEqual(category.value as? String, "Inbox")
            capture(app, "category-selector-\(appearance)")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(search.waitForNonExistence(timeout: 5))
            waitForValue("Work Engineering", of: category)
            XCTAssertTrue(editorTitle.exists, "choosing a category must not save the editor")

            app.typeKey("c", modifierFlags: [])
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            app.typeText("infosec")
            waitForValue("infosec", of: search)
            XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(options.firstMatch.label.contains("Work Infosec"))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(search.waitForNonExistence(timeout: 5))
            XCTAssertEqual(category.value as? String, "Work Engineering")
            XCTAssertTrue(editorTitle.exists)
            app.typeKey("p", modifierFlags: [])
            let prioritySearch = app.textFields["task-priority-search"]
            XCTAssertTrue(prioritySearch.waitForExistence(timeout: 5), "a field key must work immediately after cancelling a query")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(prioritySearch.waitForNonExistence(timeout: 5))

            let createdName = "Selector Created \(appearance)"
            app.typeKey("c", modifierFlags: [])
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            app.typeText(createdName)
            waitForValue(createdName, of: search)
            let create = app.buttons["task-category-create"]
            XCTAssertTrue(create.waitForExistence(timeout: 5))
            XCTAssertEqual(options.count, 0)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(search.waitForNonExistence(timeout: 5))
            waitForValue(createdName, of: category)
            XCTAssertTrue(editorTitle.exists, "creating a category must not save the editor")
            app.typeKey("c", modifierFlags: [])
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            app.typeText(createdName)
            waitForValue(createdName, of: search)
            XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(options.firstMatch.label.contains(createdName))
            XCTAssertEqual(options.count, 1)
            XCTAssertFalse(create.exists, "the locally created category should now be an existing choice")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(search.waitForNonExistence(timeout: 5))
            XCTAssertEqual(category.value as? String, createdName)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(editorTitle.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    func testDateSelectorsInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
            try typeJumpLabel(of: "demo-task-vpn", in: app)
            let editorTitle = app.textFields.matching(NSPredicate(format: "value == %@", "Renew VPN certificate")).firstMatch
            XCTAssertTrue(editorTitle.waitForExistence(timeout: 5))
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let daysToSunday = (8 - calendar.component(.weekday, from: today)) % 7
            let monday = calendar.date(byAdding: .day, value: (daysToSunday == 0 ? 7 : daysToSunday) + 1, to: today)!
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            let due = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: monday)!
            let pinned = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!
            let fields = [
                (key: "d", identifier: "task-due", query: "next mon 3pm", date: due, timed: true),
                (key: "s", identifier: "task-start", query: "tomorrow", date: tomorrow, timed: false),
                (key: "i", identifier: "task-pinned-start", query: "tomorrow 10am", date: pinned, timed: true),
            ]
            for field in fields {
                let button = app.buttons[field.identifier]
                let before = try XCTUnwrap(button.value as? String)
                let search = app.textFields["\(field.identifier)-search"]
                app.typeKey(field.key, modifierFlags: [])
                XCTAssertTrue(search.waitForExistence(timeout: 5))
                app.typeText(field.query)
                waitForValue(field.query, of: search)
                let preview = app.staticTexts["\(field.identifier)-preview"]
                let previewText = field.timed
                    ? field.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
                    : field.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
                waitForValue(previewText, of: preview)
                XCTAssertEqual(button.value as? String, before)
                if field.key == "d" { capture(app, "date-selector-\(appearance)") }
                app.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(search.waitForNonExistence(timeout: 5))
                XCTAssertEqual(button.value as? String, before)
                XCTAssertTrue(editorTitle.exists)

                app.typeKey(field.key, modifierFlags: [])
                XCTAssertTrue(search.waitForExistence(timeout: 5))
                app.typeText(field.query)
                waitForValue(field.query, of: search)
                app.typeKey(.return, modifierFlags: [])
                XCTAssertTrue(search.waitForNonExistence(timeout: 5))
                let selectedText = field.timed
                    ? field.date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
                    : field.date.formatted(.dateTime.month(.abbreviated).day().year())
                waitForValue(selectedText, of: button)
                XCTAssertTrue(editorTitle.exists, "choosing a date must not save the editor")
            }
            for (key, identifier, hour) in [("i", "task-pinned-start", 15), ("d", "task-due", 16)] {
                let button = app.buttons[identifier]
                let before = try XCTUnwrap(button.value as? String)
                app.typeKey(key, modifierFlags: [])
                let search = app.textFields["\(identifier)-search"]
                XCTAssertTrue(search.waitForExistence(timeout: 5))
                let time = app.textFields["\(identifier)-time"]
                XCTAssertTrue(time.waitForExistence(timeout: 5))
                time.click()
                app.typeKey("a", modifierFlags: .command)
                app.typeText("not a time")
                waitForValue("not a time", of: time)
                app.buttons["\(identifier)-quick-tomorrow"].click()
                XCTAssertTrue(search.exists, "a quick date must reject an invalid edited clock")
                XCTAssertEqual(button.value as? String, before)
                time.click()
                app.typeKey("a", modifierFlags: .command)
                app.typeText("\(hour - 12)pm")
                waitForValue("\(hour - 12)pm", of: time)
                app.buttons["\(identifier)-quick-tomorrow"].click()
                XCTAssertTrue(search.waitForNonExistence(timeout: 5))
                let expected = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow)!
                waitForValue(expected.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()), of: button)
                XCTAssertTrue(editorTitle.exists)
            }
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(editorTitle.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    func testSelectorKeyboardRoutingInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            defer { app.terminate() }
            let dentist = app.buttons["task-done-demo-task-dentist"]
            XCTAssertTrue(dentist.waitForExistence(timeout: 15))
            dentist.click()
            XCTAssertTrue(dentist.waitForNonExistence(timeout: 5))
            try typeJumpLabel(of: "demo-task-vpn", in: app)
            let priority = app.buttons["task-priority"]
            XCTAssertTrue(priority.waitForExistence(timeout: 5))
            for (number, value) in [("1", "ASAP"), ("2", "High"), ("3", "Medium"), ("4", "Low"), ("3", "Medium")] {
                app.typeKey(number, modifierFlags: .command)
                waitForValue(value, of: priority)
            }
            app.typeKey("z", modifierFlags: [])
            XCTAssertTrue(priority.exists)
            XCTAssertFalse(dentist.exists, "z must not undo a completion while the editor is open")
            app.typeKey("p", modifierFlags: [])
            let prioritySearch = app.textFields["task-priority-search"]
            XCTAssertTrue(prioritySearch.waitForExistence(timeout: 5))
            let medium = app.buttons["task-priority-option-2"]
            let low = app.buttons["task-priority-option-3"]
            waitForValue("Highlighted", of: medium)
            app.typeKey(.downArrow, modifierFlags: [])
            waitForValue("Highlighted", of: low)
            app.typeKey("p", modifierFlags: .control)
            waitForValue("Highlighted", of: medium)
            app.typeKey("n", modifierFlags: .control)
            waitForValue("Highlighted", of: low)
            app.typeKey(.upArrow, modifierFlags: [])
            waitForValue("Highlighted", of: medium)
            app.typeKey("n", modifierFlags: .control)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(prioritySearch.waitForNonExistence(timeout: 5))
            waitForValue("Low", of: priority)

            app.typeKey("d", modifierFlags: [])
            let dueSearch = app.textFields["task-due-search"]
            XCTAssertTrue(dueSearch.waitForExistence(timeout: 5))
            app.typeKey(.rightArrow, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(dueSearch.waitForNonExistence(timeout: 5))
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            waitForValue(today.formatted(.dateTime.month(.abbreviated).day().year()), of: app.buttons["task-due"])

            app.typeKey("s", modifierFlags: [])
            let startSearch = app.textFields["task-start-search"]
            XCTAssertTrue(startSearch.waitForExistence(timeout: 5))
            app.typeKey(.tab, modifierFlags: [])
            app.typeKey("2", modifierFlags: [])
            XCTAssertTrue(startSearch.waitForNonExistence(timeout: 5), "a single number on the calendar must pick its quick date")
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            let afterTomorrow = calendar.date(byAdding: .day, value: 2, to: today)!
            waitForValue(tomorrow.formatted(.dateTime.month(.abbreviated).day().year()), of: app.buttons["task-start"])
            waitForValue(afterTomorrow.formatted(.dateTime.month(.abbreviated).day().year()), of: app.buttons["task-due"])
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(priority.waitForNonExistence(timeout: 5))
            XCTAssertFalse(dentist.exists)
            app.typeKey("z", modifierFlags: [])
            XCTAssertTrue(dentist.waitForExistence(timeout: 5), "z must work again after leaving the editor")
        }
    }

    @MainActor
    func testTaskPaneClicksInBothAppearances() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            defer { app.terminate() }
            let title = app.staticTexts["Renew VPN certificate"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 15))
            let row = app.descendants(matching: .any).matching(identifier: "task-row-demo-task-vpn").firstMatch
            XCTAssertTrue(row.exists)
            let priority = app.buttons["task-priority"]
            title.click()
            waitForLabel("Selected task, Renew VPN certificate", of: row)
            capture(app.windows.firstMatch, "task-selection-\(appearance)")
            let editorTitle = app.textFields.matching(NSPredicate(format: "value == %@", "Renew VPN certificate")).firstMatch
            XCTAssertTrue(editorTitle.waitForExistence(timeout: 5), "one click must open the clicked task")
            XCTAssertTrue(priority.exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(editorTitle.waitForNonExistence(timeout: 5))
            waitForLabel("Selected task, Renew VPN certificate", of: row)
            app.typeKey("e", modifierFlags: [])
            XCTAssertTrue(editorTitle.waitForExistence(timeout: 5), "E must act on the task-pane selection after the editor closes")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(editorTitle.waitForNonExistence(timeout: 5))

            let done = app.buttons["task-done-demo-task-vpn"]
            XCTAssertTrue(done.isHittable)
            done.click()
            XCTAssertTrue(title.waitForNonExistence(timeout: 5), "one click on the completion circle must finish the task")
            XCTAssertTrue(done.waitForNonExistence(timeout: 5))
            XCTAssertFalse(priority.exists)
            app.typeKey("z", modifierFlags: [])
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            title.doubleClick()
            XCTAssertTrue(editorTitle.waitForExistence(timeout: 5), "a double click must open the correct task")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(editorTitle.waitForNonExistence(timeout: 5))
        }
    }

    /// Dragging an event that repeats. Dropped on its own day it asks whether this one moves or
    /// all of them; All Events moves it and `z` moves it back. Dropped on another day only this
    /// one can move, and Cancel puts the block back.
    @MainActor
    func testDraggingARepeatingEventAsksWhichToMove() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiAppearance", "light"]
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 10))

        // The demo's time grid shows an hour in 60 points: 90 points down is an hour and a half.
        let home = standupPopoverFrame(in: app)
        let windowFrame = window.frame
        let block = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: home.minX - windowFrame.minX - 40, dy: home.midY - windowFrame.minY))
        block.press(forDuration: 0.3, thenDragTo: block.withOffset(CGVector(dx: 0, dy: 90)), withVelocity: .slow, thenHoldForDuration: 0.3)
        // Scoped to the sheet: CI's Mac also lists the dialog's buttons under a Touch Bar element.
        let thisEvent = app.sheets.buttons["This Event"]
        let allEvents = app.sheets.buttons["All Events"]
        XCTAssertTrue(allEvents.waitForExistence(timeout: 5), "a repeating event dropped on its own day should ask which to move")
        XCTAssertTrue(thisEvent.exists)
        capture(window, "move-repeating-event")
        allEvents.click()
        XCTAssertTrue(allEvents.waitForNonExistence(timeout: 5))
        XCTAssertEqual(standupPopoverFrame(in: app).midY, home.midY + 90, accuracy: 8, "All Events should move the event")

        app.typeKey("z", modifierFlags: [])
        XCTAssertEqual(standupPopoverFrame(in: app).midY, home.midY, accuracy: 2, "z should move it back")

        block.press(forDuration: 0.3, thenDragTo: block.withOffset(CGVector(dx: 220, dy: 60)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(thisEvent.waitForExistence(timeout: 5), "dropped on another day it should still ask")
        XCTAssertFalse(allEvents.exists, "a drop on another day can only move this one")
        capture(window, "move-repeating-event-other-day")
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(thisEvent.waitForNonExistence(timeout: 5))
        XCTAssertEqual(standupPopoverFrame(in: app).midY, home.midY, accuracy: 2, "Cancel should leave it where it was")
    }

    /// Jump mode: `f` labels every item, a label opens its item, and Escape takes the labels
    /// down. The grid is a canvas the test cannot read, so labels come from the task pane's rows:
    /// one task that is also on the grid, one that is only in the pane.
    @MainActor
    func testJumpLabelsInBothAppearances() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoData", "YES", "-uiAppearance", appearance]
            app.launch()
            defer { app.terminate() }
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 10))

            // Only what is on screen gets a label. The VPN task's row is at the top of the task
            // pane; the funds task's row is below the fold, and it has no block in these days.
            let nearTop = app.staticTexts["task-jump-demo-task-vpn"]
            let atEnd = app.staticTexts["task-jump-demo-task-funds"]
            app.typeKey("f", modifierFlags: [])
            XCTAssertTrue(nearTop.waitForExistence(timeout: 5))
            XCTAssertFalse(atEnd.exists, "a row scrolled out of view should get no label")
            capture(window, "jump-\(appearance)")

            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(nearTop.waitForNonExistence(timeout: 5))

            // Choosing an event label opens its details, by keyboard or by clicking the badge.
            for click in [false, true] {
                app.typeKey("f", modifierFlags: [])
                let eventLabel = app.staticTexts["event-jump-demo-event-offsite"]
                XCTAssertTrue(eventLabel.waitForExistence(timeout: 5))
                if click {
                    app.buttons["Today"].hover()
                    eventLabel.hover()
                    eventLabel.click()
                } else {
                    let keys = try XCTUnwrap(eventLabel.value as? String).lowercased()
                    for key in keys { app.typeKey(String(key), modifierFlags: []) }
                }
                XCTAssertTrue(app.buttons["Edit…"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["Half Moon Bay"].exists)
                capture(window, "jump-event-\(click ? "click" : "key")-\(appearance)")
                app.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(app.buttons["Edit…"].waitForNonExistence(timeout: 5))
            }

            // A task on the calendar and in the pane, then one in the pane only.
            try jump(to: "demo-task-pr", titled: "Review auth service PR", in: app)
            try jump(to: "demo-task-vpn", titled: "Renew VPN certificate", in: app)

            // Each `f` labels the view as it is then. `G` in the task pane scrolls the list to its end.
            app.typeKey("g", modifierFlags: [])
            app.typeKey("t", modifierFlags: [])
            app.typeKey("g", modifierFlags: .shift)
            try jump(to: "demo-task-funds", titled: "Rebalance index funds", in: app) {
                XCTAssertFalse(nearTop.exists, "a row scrolled out of view should get no label")
            }

            // `g g` scrolls the list back to its start. Its first row stops under the pinned
            // section header, so the check is on the second task.
            app.typeKey("g", modifierFlags: [])
            app.typeKey("g", modifierFlags: [])
            app.typeKey("f", modifierFlags: [])
            let second = app.staticTexts["task-jump-demo-task-offsite"]
            XCTAssertTrue(second.waitForExistence(timeout: 5))
            XCTAssertFalse(atEnd.exists, "a row scrolled out of view should get no label")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(second.waitForNonExistence(timeout: 5))

            // `G` on the calendar scrolls the grid down to the last block of these days, which
            // leaves earlier blocks cut off at the top or out of view.
            app.typeKey("g", modifierFlags: [])
            app.typeKey("c", modifierFlags: [])
            app.typeKey("g", modifierFlags: .shift)
            app.typeKey("f", modifierFlags: [])
            let anyLabel = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'task-jump-'")).firstMatch
            XCTAssertTrue(anyLabel.waitForExistence(timeout: 5))
            capture(window, "jump-scrolled-\(appearance)")
        }
    }

    /// `f`, then the label on the task's row in the pane, which opens the task: the editor's
    /// title says which task the label chose. `whileLabelled` runs with the labels up.
    @MainActor
    private func jump(
        to id: String, titled title: String, in app: XCUIApplication, whileLabelled: () -> Void = {}
    ) throws {
        try typeJumpLabel(of: id, in: app, whileLabelled: whileLabelled)
        let editorTitle = app.textFields.matching(NSPredicate(format: "value == %@", title)).firstMatch
        XCTAssertTrue(editorTitle.waitForExistence(timeout: 5), "the label should open \(title)")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(editorTitle.waitForNonExistence(timeout: 5))
    }

    /// The frame of the Standup's detail popover, which points at the event's block from the
    /// block's right. The grid is a canvas the test cannot read, so this is how it finds the
    /// block: search selects the event, Return opens the popover, Escape closes it.
    @MainActor
    private func standupPopoverFrame(in app: XCUIApplication) -> CGRect {
        app.typeKey("/", modifierFlags: [])
        let input = app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("Standup")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        let edit = app.buttons["Edit…"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        let frame = app.popovers.firstMatch.frame
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
        return frame
    }

    /// Presses `f`, then types the label on the task's row in the pane.
    @MainActor
    private func typeJumpLabel(of id: String, in app: XCUIApplication, whileLabelled: () -> Void = {}) throws {
        app.typeKey("f", modifierFlags: [])
        let label = app.staticTexts["task-jump-\(id)"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        whileLabelled()
        let keys = try XCTUnwrap(label.value as? String).lowercased()
        XCTAssertFalse(keys.isEmpty)
        for key in keys {
            app.typeKey(String(key), modifierFlags: [])
        }
        XCTAssertTrue(label.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement) {
        wait(for: [expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)], timeout: 5)
    }

    @MainActor
    private func waitForLabel(_ label: String, of element: XCUIElement) {
        wait(for: [expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)], timeout: 5)
    }

    @MainActor
    private func capture(_ window: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
