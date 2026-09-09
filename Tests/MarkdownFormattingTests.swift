import Foundation
import XCTest
@testable import Beacon

final class MarkdownFormattingTests: XCTestCase {
    func testStrongAndEmphasizedMarkersBecomePresentationAttributes() {
        let result = BeaconMarkdown.attributedString(
            "Choose **Save** and *wait for the confirmation*."
        )

        XCTAssertEqual(
            String(result.characters),
            "Choose Save and wait for the confirmation."
        )
        let intents = result.runs.compactMap(\.inlinePresentationIntent)
        XCTAssertTrue(intents.contains { $0.contains(.stronglyEmphasized) })
        XCTAssertTrue(intents.contains { $0.contains(.emphasized) })
    }

    func testMalformedMarkdownStillProducesReadableText() {
        let result = BeaconMarkdown.plainText("Choose **Save")

        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.contains("Save"))
    }
}
