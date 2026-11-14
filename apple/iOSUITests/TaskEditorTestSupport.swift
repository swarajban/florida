import XCTest

extension XCTestCase {
    @MainActor
    func setTaskEditorSwitch(
        _ identifier: String, on: Bool, in app: XCUIApplication, upwards: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let control = revealTaskEditorControl(app.switches[identifier], in: app, upwards: upwards, file: file, line: line)
        XCTAssertEqual(control.value as? String, on ? "0" : "1", file: file, line: line)
        control.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", on ? "1" : "0"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed,
                       "The editor switch must change to \(on ? "on" : "off")", file: file, line: line)
    }

    @MainActor
    @discardableResult
    func revealTaskEditorControl(
        _ resolve: @autoclosure () -> XCUIElement, in app: XCUIApplication, upwards: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement {
        let form = app.collectionViews["task-editor-form"]
        XCTAssertTrue(form.waitForExistence(timeout: 5), file: file, line: line)
        let top = max(app.navigationBars["Edit Task"].frame.maxY, form.frame.minY) + 4
        let bottom = form.frame.maxY - 8
        let middle = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: form.frame.midX, dy: (top + bottom) / 2))
        for _ in 0..<20 {
            let row = resolve()
            var travel: CGFloat = upwards ? 160 : -160
            if row.exists {
                let cell = form.cells.containing(NSPredicate(format: "identifier == %@", row.identifier)).firstMatch
                let frame = cell.exists ? cell.frame : .zero
                if !frame.isEmpty, [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) {
                    if frame.minY >= top, frame.maxY <= bottom {
                        let control = row.elementType == .switch ? row.switches.firstMatch : row
                        XCTAssertTrue(control.waitForExistence(timeout: 5), file: file, line: line)
                        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: control)
                        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed,
                                       "The native editor control must be visible and hittable", file: file, line: line)
                        let target = control.frame
                        XCTAssertFalse(target.isEmpty, file: file, line: line)
                        XCTAssertTrue([target.minX, target.minY, target.maxX, target.maxY].allSatisfy(\.isFinite), file: file, line: line)
                        XCTAssertGreaterThanOrEqual(target.minY, top, file: file, line: line)
                        XCTAssertLessThanOrEqual(target.maxY, bottom, file: file, line: line)
                        return control
                    }
                    let distance = frame.minY < top ? top - frame.minY : bottom - frame.maxY
                    travel = distance > 0 ? min(160, max(24, distance)) : max(-160, min(-24, distance))
                }
            }
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: travel)),
                         withVelocity: .slow, thenHoldForDuration: 0)
        }
        XCTFail("The editor cell must fit inside its form viewport", file: file, line: line)
        return resolve()
    }
}
