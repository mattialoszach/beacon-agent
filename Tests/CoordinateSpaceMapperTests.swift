import CoreGraphics
import XCTest
@testable import Beacon

final class CoordinateSpaceMapperTests: XCTestCase {
    func testGlobalCursorMapsIntoTopLeftSwiftUICoordinatesWithNegativeDisplayOrigin() {
        let frame = CGRect(x: -1440, y: 120, width: 1440, height: 900)

        XCTAssertEqual(
            CoordinateSpaceMapper.localSwiftUIPoint(
                fromGlobalAppKit: CGPoint(x: -720, y: 795),
                in: frame
            ),
            CGPoint(x: 720, y: 225)
        )
    }

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

    func testScreenshotMappingRoundTripsThroughDisplayBounds() throws {
        let display = NormalizedRect(x: 0.0, y: 0.25, width: 0.4, height: 0.5)
        let pixels = CGRect(x: 240, y: 180, width: 320, height: 120)
        let pixelSize = CGSize(width: 1_600, height: 900)

        let normalized = try XCTUnwrap(CoordinateSpaceMapper.normalizedScreenshotRect(
            pixelRect: pixels,
            pixelSize: pixelSize,
            displayBounds: display
        ))
        let roundTrip = try XCTUnwrap(CoordinateSpaceMapper.screenshotPixelRect(
            from: normalized,
            pixelSize: pixelSize,
            displayBounds: display
        ))

        XCTAssertEqual(roundTrip.minX, pixels.minX, accuracy: 0.001)
        XCTAssertEqual(roundTrip.minY, pixels.minY, accuracy: 0.001)
        XCTAssertEqual(roundTrip.width, pixels.width, accuracy: 0.001)
        XCTAssertEqual(roundTrip.height, pixels.height, accuracy: 0.001)
    }

    func testScreenshotMappingRejectsRectOutsideSourceDisplay() {
        let display = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let outside = NormalizedRect(x: 0.2, y: 0.1, width: 0.1, height: 0.1)

        XCTAssertNil(CoordinateSpaceMapper.screenshotPixelRect(
            from: outside,
            pixelSize: CGSize(width: 1_000, height: 800),
            displayBounds: display
        ))
    }

    func testScreenshotMappingClipsRectCrossingDisplayBoundary() throws {
        let display = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let crossing = NormalizedRect(x: 0.45, y: 0.1, width: 0.1, height: 0.2)

        let result = try XCTUnwrap(CoordinateSpaceMapper.screenshotPixelRect(
            from: crossing,
            pixelSize: CGSize(width: 1_000, height: 800),
            displayBounds: display
        ))

        XCTAssertEqual(result.minX, 0, accuracy: 0.001)
        XCTAssertEqual(result.width, 100, accuracy: 0.001)
    }

    func testBottomLeftImageMappingInvertsYAxisOnce() throws {
        let result = try XCTUnwrap(CoordinateSpaceMapper.normalizedBottomLeftImageRect(
            CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.2),
            pixelSize: CGSize(width: 1_000, height: 800),
            displayBounds: .init(x: 0, y: 0, width: 1, height: 1)
        ))

        XCTAssertEqual(result.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(result.y, 0.7, accuracy: 0.001)
        XCTAssertEqual(result.width, 0.3, accuracy: 0.001)
        XCTAssertEqual(result.height, 0.2, accuracy: 0.001)
    }

    func testBitmapDrawingMappingUsesBottomLeftOrigin() throws {
        let result = try XCTUnwrap(CoordinateSpaceMapper.bitmapDrawingRect(
            from: .init(x: 0.2, y: 0.1, width: 0.3, height: 0.2),
            pixelSize: CGSize(width: 1_000, height: 800),
            displayBounds: .init(x: 0, y: 0, width: 1, height: 1)
        ))

        XCTAssertEqual(result.minX, 200, accuracy: 0.001)
        XCTAssertEqual(result.minY, 560, accuracy: 0.001)
        XCTAssertEqual(result.width, 300, accuracy: 0.001)
        XCTAssertEqual(result.height, 160, accuracy: 0.001)
    }
}
