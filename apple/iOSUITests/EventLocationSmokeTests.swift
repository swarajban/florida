import XCTest

final class EventLocationSmokeTests: XCTestCase {
    @MainActor
    func testAgendaLocationOffersGoogleMapsDirections() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "YES", "-uiTab", "agenda", "-uiAgendaMode", "list",
                               "-uiAppearance", "light", "-uiRecordMapOpens", "YES"]
        let location = app.buttons["event-location-demo-event-offsite"]
        let directions = app.buttons["Directions"]
        addTeardownBlock { @MainActor [weak self] in
            guard let self, (self.testRun?.failureCount ?? 0) > 0 else { return }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "event-location-assertion-failure"
            screenshot.lifetime = .keepAlways
            self.add(screenshot)
            print("Location: exists=\(location.exists), frame=\(location.frame), value=\(String(describing: location.value)); Directions: exists=\(directions.exists), frame=\(directions.frame)")
        }
        app.launch()
        XCTAssertTrue(location.waitForExistence(timeout: 10))
        for _ in 0..<3 where !location.isHittable { app.swipeUp() }
        XCTAssertTrue(location.isHittable)
        location.tap()
        XCTAssertTrue(directions.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open in Google Maps"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "event-location-google-maps-menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        directions.tap()
        XCTAssertEqual(location.value as? String, "https://www.google.com/maps/dir/?api=1&destination=Half%20Moon%20Bay")
        XCTAssertFalse(app.navigationBars["Event"].exists)
    }
}
