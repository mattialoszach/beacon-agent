import XCTest
@testable import Beacon

final class NormalizedRectTests: XCTestCase {
    func testValidationRejectsOverflowAndNonFiniteValues() {
        XCTAssertTrue(NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4).isValid)
        XCTAssertFalse(NormalizedRect(x: 0.9, y: 0, width: 0.2, height: 1).isValid)
        XCTAssertFalse(NormalizedRect(x: .nan, y: 0, width: 1, height: 1).isValid)
    }

    func testClampingProducesValidRect() {
        let result = NormalizedRect.clamped(x: -4, y: 0.9, width: 3, height: 2)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.x, 0)
        XCTAssertEqual(result.height, 0.1, accuracy: 0.0001)
    }
}
