import XCTest

extension XCTestCase {
    @MainActor
    func setTaskEditorSwitch(
        _ identifier: String, on: Bool, in app: XCUIApplication, upwards: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        revealTaskEditorControl(app.switches[identifier], in: app, upwards: upwards, file: file, line: line)
        let control = app.switches[identifier]
        XCTAssertEqual(control.value as? String, on ? "0" : "1", file: file, line: line)
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", on ? "1" : "0"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed,
                       "The editor switch must change to \(on ? "on" : "off")", file: file, line: line)
    }

    @MainActor
    func revealTaskEditorControl(
        _ resolve: @autoclosure () -> XCUIElement, in app: XCUIApplication, upwards: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let form = app.collectionViews["task-editor-form"]
        XCTAssertTrue(form.waitForExistence(timeout: 5), file: file, line: line)
        let top = app.navigationBars["Edit Task"].frame.maxY + 4
        let bottom = form.frame.maxY - 8
        for _ in 0..<10 {
            let control = resolve()
            if control.exists {
                let frame = control.frame
                if !frame.isEmpty, [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) {
                    if frame.minY >= top, frame.maxY <= bottom, control.isHittable { break }
                    if frame.minY < top { form.swipeDown() } else { form.swipeUp() }
                } else if upwards {
                    form.swipeDown()
                } else {
                    form.swipeUp()
                }
            } else if upwards {
                form.swipeDown()
            } else {
                form.swipeUp()
            }
        }
        let control = resolve()
        XCTAssertTrue(control.waitForExistence(timeout: 5), file: file, line: line)
        let frame = control.frame
        guard !frame.isEmpty, [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) else {
            XCTFail("The editor control must have a finite, nonempty frame", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(frame.minY, top, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, bottom, file: file, line: line)
        XCTAssertTrue(control.isHittable, file: file, line: line)
    }
}
