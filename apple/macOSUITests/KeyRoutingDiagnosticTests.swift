import AppKit
import ApplicationServices
import XCTest

final class KeyRoutingDiagnosticTests: XCTestCase {
    @MainActor
    func testNeutralUndoAfterEditorDismissal() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let diagnostics = app.staticTexts["editor-diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 15))
        app.typeKey("/", modifierFlags: [])
        let search = app.textFields["palette-input"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Renew VPN certificate")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        app.typeKey("4", modifierFlags: .command)
        waitForValue("taskWrites=1 queueChanges=1 sounds=0 pendingRows=1 syncApplied=false", on: diagnostics)
        app.typeKey("e", modifierFlags: [])
        let title = app.textFields["task-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        app.typeKey("a", modifierFlags: .command)
        title.typeText("Unsaved routing probe title")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        captureFocus("after-editor-dismissal", in: app)
        app.typeKey("z", modifierFlags: [])
        captureFocus("after-undo-key", in: app)
        waitForValue("taskWrites=2 queueChanges=2 sounds=0 pendingRows=1 syncApplied=false", on: diagnostics)
        app.typeKey("e", modifierFlags: [])
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Renew VPN certificate")
    }

    @MainActor
    func testNeutralJumpAfterClickOpenedEventPopoverDismissal() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Book dentist appointment"].waitForExistence(timeout: 15))
        app.typeKey("f", modifierFlags: [])
        let event = app.staticTexts["event-jump-demo-event-offsite"]
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        app.buttons["Today"].hover()
        event.hover()
        event.click()
        let edit = app.buttons["Edit…"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        captureFocus("click-opened-popover", in: app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
        captureFocus("after-click-popover-dismissal", in: app)
        app.typeKey("f", modifierFlags: [])
        captureFocus("after-jump-key", in: app)
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("c", modifierFlags: [])
        let capture = app.textFields["palette-input"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        captureFocus("after-capture-key", in: app)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-demoData", "YES", "-uiAppearance", "light", "-uiEditorDiagnostics", "YES", "-joy.ghosts", "NO",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func captureFocus(_ stage: String, in app: XCUIApplication) {
        var lines = [stage]
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.swarajban.florida").first {
            let application = AXUIElementCreateApplication(running.processIdentifier)
            for attribute in [kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute] {
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(application, attribute as CFString, &value)
                lines.append("\(attribute): result=\(result.rawValue)")
                if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let element = unsafeBitCast(value, to: AXUIElement.self)
                    for key in [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute] {
                        var field: CFTypeRef?
                        let code = AXUIElementCopyAttributeValue(element, key as CFString, &field)
                        lines.append("  \(key): result=\(code.rawValue) value=\(field.map { String(describing: $0) } ?? "nil")")
                    }
                }
            }
        }
        lines.append(app.debugDescription)
        let state = XCTAttachment(string: lines.joined(separator: "\n"))
        state.name = "key-routing-\(stage)"
        state.lifetime = .keepAlways
        add(state)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "key-routing-\(stage)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func waitForValue(_ value: String, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
