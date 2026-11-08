import FloridaKit
import XCTest

final class FloridaKitTests: XCTestCase {
    func testAppGroup() {
        XCTAssertEqual(Florida.appGroup, "group.com.swarajban.florida")
    }
}
