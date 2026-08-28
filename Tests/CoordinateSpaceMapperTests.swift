import CoreGraphics
import XCTest
@testable import Beacon

final class CoordinateSpaceMapperTests: XCTestCase {
    private let mapper = CoordinateSpaceMapper(
        virtualDesktopBounds: CGRect(x: -1440, y: 0, width: 3360, height: 1080),
        appKitMainScreenMaxY: 1080
    )

    func testAXRectRoundTripAcrossTwoDisplays() throws {
        let original = CGRect(x: -1200, y: 100, width: 240, height: 90)
        let normalized = try XCTUnwrap(mapper.normalizeAXRect(original))

        XCTAssertTrue(normalized.isValid)
        XCTAssertEqual(try XCTUnwrap(mapper.axRect(from: normalized)).minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(mapper.axRect(from: normalized)).minY, original.minY, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(mapper.axRect(from: normalized)).width, original.width, accuracy: 0.001)
    }

    func testAppKitConversionInvertsYAxisOnce() throws {
        let normalized = try XCTUnwrap(mapper.normalizeAXRect(CGRect(x: 10, y: 100, width: 100, height: 50)))
        let appKit = try XCTUnwrap(mapper.appKitRect(from: normalized))

        XCTAssertEqual(appKit.origin.x, 10, accuracy: 0.001)
        XCTAssertEqual(appKit.origin.y, 930, accuracy: 0.001)
    }

    func testScreenshotPixelsMapIntoDisplayBounds() throws {
        let display = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let result = try XCTUnwrap(mapper.normalizedScreenshotRect(
            pixelRect: CGRect(x: 100, y: 50, width: 200, height: 100),
            pixelSize: CGSize(width: 1000, height: 500),
            displayBounds: display
        ))

        XCTAssertEqual(result.x, 0.55, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.width, 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.height, 0.2, accuracy: 0.0001)
    }
}
