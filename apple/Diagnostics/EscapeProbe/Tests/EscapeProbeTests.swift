import XCTest

final class EscapeProbeTests: XCTestCase {
    @MainActor
    func testEscapeDelivery() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let trace = app.otherElements["probe-trace"]
        XCTAssertTrue(trace.waitForExistence(timeout: 10))
        let ready = NSPredicate(format: "value CONTAINS %@", "\"firstResponder\":true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: trace)], timeout: 10), .completed)
        let baseline = try capture(trace, name: "before-tab")
        XCTAssertEqual(baseline["marked"] as? Bool, false)

        app.typeKey(.tab, modifierFlags: [])
        let tab = try capture(trace, name: "after-tab")
        app.typeKey(.escape, modifierFlags: [])
        let received = NSPredicate(format: "value CONTAINS %@", "\"41\":")
        let wait = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: received, object: trace)], timeout: 3)
        let escape = try capture(trace, name: "after-escape")
        let verdict = ["application", "window", "textView"].map { layer in
            "\(layer)=\(count(escape, layer: layer, code: "41") - count(tab, layer: layer, code: "41"))"
        }.joined(separator: ",")
        let summary = "XCUI Escape began deltas: \(verdict); observation=\(wait == .completed ? "received" : "not observed within 3s"). Absence is diagnostic evidence, not a passing physical-key assertion."
        print("[EscapeProbe] \(summary)")
        let attachment = XCTAttachment(string: summary)
        attachment.name = "escape-verdict"
        attachment.lifetime = .keepAlways
        add(attachment)

        for layer in ["application", "window", "textView"] {
            XCTAssertGreaterThan(count(tab, layer: layer, code: "43"), count(baseline, layer: layer, code: "43"), "Missing Tab positive control at \(layer)")
        }
        XCTAssertEqual(tab["firstResponder"] as? Bool, true)
        XCTAssertEqual(tab["marked"] as? Bool, false)
    }

    @MainActor
    private func snapshot(_ trace: XCUIElement) throws -> [String: Any] {
        let value = trace.value as? String ?? ""
        let json = try JSONSerialization.jsonObject(with: Data(value.utf8))
        return try XCTUnwrap(json as? [String: Any])
    }

    @MainActor
    private func capture(_ trace: XCUIElement, name: String) throws -> [String: Any] {
        let state = try snapshot(trace)
        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        let value = String(decoding: data, as: UTF8.self)
        print("[EscapeProbe] \(name): \(value)")
        let attachment = XCTAttachment(string: value)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return state
    }

    private func count(_ state: [String: Any], layer: String, code: String) -> Int {
        let codes = state["beganCodes"] as? [String: [String: Int]]
        return codes?[layer]?[code] ?? 0
    }
}
