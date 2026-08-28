import XCTest
@testable import Beacon

final class RequestModeClassifierTests: XCTestCase {
    private let classifier = RequestModeClassifier()

    func testExplanatoryRequestsAreQuestions() {
        XCTAssertEqual(classifier.classify("What does this warning mean?"), .ask)
        XCTAssertEqual(classifier.classify("Why is this disabled?"), .ask)
        XCTAssertEqual(classifier.classify("How does this tool work?"), .ask)
    }

    func testActionableRequestsStartGuidance() {
        XCTAssertEqual(classifier.classify("Where is Export?"), .guide)
        XCTAssertEqual(classifier.classify("How do I export as PDF?"), .guide)
        XCTAssertEqual(classifier.classify("Export this as a PDF"), .guide)
    }
}
