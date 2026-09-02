import XCTest
@testable import Beacon

final class BeaconLaunchOptionsTests: XCTestCase {
    func testThinkingPreviewRequiresExplicitFlag() {
        XCTAssertTrue(BeaconLaunchOptions.isThinkingPreview(
            arguments: ["Beacon", "--preview-thinking"]
        ))
        XCTAssertFalse(BeaconLaunchOptions.isThinkingPreview(
            arguments: ["Beacon"]
        ))
    }
}
