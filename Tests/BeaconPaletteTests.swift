import XCTest
@testable import Beacon

final class BeaconPaletteTests: XCTestCase {
    func testCanonicalHexValues() {
        XCTAssertEqual(BeaconPalette.Hex.lavender, 0xE6E6FA)
        XCTAssertEqual(BeaconPalette.Hex.thistle, 0xD8BFD8)
        XCTAssertEqual(BeaconPalette.Hex.plum, 0xDDA0DD)
        XCTAssertEqual(BeaconPalette.Hex.mediumPurple, 0x9370DB)
        XCTAssertEqual(BeaconPalette.Hex.blueViolet, 0x8A2BE2)
    }
}
