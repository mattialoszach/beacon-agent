import XCTest
@testable import Beacon

final class SensitiveTextDetectorTests: XCTestCase {
    private let detector = SensitiveTextDetector()

    func testClassifiesCommonSensitiveValues() {
        XCTAssertEqual(detector.kind(of: "person@example.com"), .emailAddress)
        XCTAssertEqual(detector.kind(of: "+41 79 123 45 67"), .phoneNumber)
        XCTAssertEqual(detector.kind(of: "4242 4242 4242 4242"), .creditCard)
        XCTAssertEqual(detector.kind(of: "sk-abcdefghijklmnopqrstuvwxyz1234"), .apiKey)
    }

    func testDoesNotRedactOrdinaryUILabels() {
        XCTAssertNil(detector.kind(of: "Export as PDF"))
        XCTAssertNil(detector.kind(of: "Page 12 of 85"))
    }

    func testSensitiveVisualElementsAreRemovedAndMappedToRegions() {
        let elements = [
            visual(id: "safe", text: "Save"),
            visual(id: "secret", text: "person@example.com")
        ]
        XCTAssertEqual(detector.removingSensitiveElements(from: elements).map(\.id), ["safe"])
        XCTAssertEqual(detector.redactionRegions(in: elements).count, 1)
    }

    private func visual(id: String, text: String) -> VisualElementDescriptor {
        .init(id: id, text: text, bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.05), confidence: 0.9)
    }
}
