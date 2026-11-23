import XCTest

final class LaterSmokeTests: XCTestCase {
    @MainActor
    func testLaterQueueAndCatchUp() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiLaterFixture", "YES",
            "-uiTab", "tasks", "-uiAgendaMode", "list", "-uiAppearance", "light"]
        app.launch()
        addTeardownBlock { @MainActor in
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Later smoke"
            screenshot.lifetime = .keepAlways
            self.add(screenshot)
        }

        let later = element("tasks-later-link", in: app)
        assertVisible(later, in: app)
        XCTAssertEqual(later.value as? String, "1 unread")
        later.tap()
        let story = element("later-item-test-story", in: app)
        assertVisible(story, in: app)
        story.swipeRight()
        let markRead = app.buttons["Mark read"]
        assertVisible(markRead, in: app)
        markRead.tap()
        XCTAssertTrue(story.waitForNonExistence(timeout: 4))

        app.tabBars.buttons["Agenda"].tap()
        assertVisible(element("agenda-catch-up-test-catch-up", in: app), in: app)
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func assertVisible(_ element: XCUIElement, in app: XCUIApplication, line: UInt = #line) {
        let exists = element.waitForExistence(timeout: 5)
        guard exists, element.isHittable else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Failed at line \(line)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("\(element): exists=\(exists), hittable=\(element.isHittable), frame=\(element.frame)", line: line)
            return
        }
    }
}
