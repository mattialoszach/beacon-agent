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

// MARK: - Displays above the main screen, clipping, and rejection

final class CoordinateSpaceMapperEdgeCaseTests: XCTestCase {
    /// A 1440x900 display sitting above a 1440x900 main display: Quartz Y is negative
    /// there while AppKit Y exceeds the main screen height.
    private let aboveMainMapper = CoordinateSpaceMapper(
        virtualDesktopBounds: CGRect(x: 0, y: -900, width: 1440, height: 1800),
        appKitMainScreenMaxY: 900
    )

    func testAppKitConversionUsesMainScreenHeightNotDesktopHeight() throws {
        let normalized = try XCTUnwrap(
            aboveMainMapper.normalizeAXRect(CGRect(x: 100, y: -800, width: 200, height: 50))
        )
        let appKit = try XCTUnwrap(aboveMainMapper.appKitRect(from: normalized))

        XCTAssertEqual(appKit.origin.x, 100, accuracy: 0.001)
        // Quartz top edge -800 is 800 points above the main screen top (900 in AppKit).
        XCTAssertEqual(appKit.maxY, 1700, accuracy: 0.001)
        XCTAssertEqual(appKit.origin.y, 1650, accuracy: 0.001)
    }

    func testRoundTripSurvivesNegativeQuartzOrigin() throws {
        let original = CGRect(x: 20, y: -880, width: 300, height: 120)
        let normalized = try XCTUnwrap(aboveMainMapper.normalizeAXRect(original))
        let restored = try XCTUnwrap(aboveMainMapper.axRect(from: normalized))

        XCTAssertEqual(restored.minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(restored.minY, original.minY, accuracy: 0.001)
        XCTAssertEqual(restored.height, original.height, accuracy: 0.001)
    }

    private let mapper = CoordinateSpaceMapper(
        virtualDesktopBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
        appKitMainScreenMaxY: 900
    )

    func testStrictNormalizationRejectsRectanglesLeavingTheDesktop() {
        XCTAssertNil(mapper.normalizeAXRect(CGRect(x: 1400, y: 10, width: 200, height: 20)))
        XCTAssertNil(mapper.normalizeAXRect(CGRect(x: -10, y: 10, width: 100, height: 20)))
        XCTAssertNil(mapper.normalizeAXRect(CGRect(x: 0, y: 0, width: 4000, height: 3000)))
        XCTAssertNil(mapper.normalizeAXRect(CGRect(x: 10, y: 880, width: 100, height: 40)))
    }

    func testStrictNormalizationRejectsNonFiniteRectangles() {
        XCTAssertNil(mapper.normalizeAXRect(CGRect(x: CGFloat.nan, y: 10, width: 100, height: 20)))
        XCTAssertNil(mapper.normalizeAXRect(CGRect(x: 10, y: 10, width: CGFloat.infinity, height: 20)))
    }

    func testZeroSizeDesktopCannotNormalize() {
        let degenerate = CoordinateSpaceMapper(
            virtualDesktopBounds: CGRect(x: 0, y: 0, width: 0, height: 0),
            appKitMainScreenMaxY: 0
        )
        XCTAssertNil(degenerate.normalizeAXRect(CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertNil(degenerate.normalizeAXRect(clippingToDesktop: CGRect(x: 0, y: 0, width: 10, height: 10)))
    }

    func testClippingKeepsTheVisiblePartOfAPartlyOffscreenWindow() throws {
        // A window pushed 100 points past the right edge keeps its visible 900 points.
        let clipped = try XCTUnwrap(
            mapper.normalizeAXRect(clippingToDesktop: CGRect(x: 540, y: 100, width: 1000, height: 200))
        )

        XCTAssertEqual(clipped.x, 540.0 / 1440.0, accuracy: 0.000_001)
        XCTAssertEqual(clipped.width, 900.0 / 1440.0, accuracy: 0.000_001)
        XCTAssertTrue(clipped.isValid)
    }

    func testClippingKeepsTheVisiblePartOfANegativeOriginRectangle() throws {
        let clipped = try XCTUnwrap(
            mapper.normalizeAXRect(clippingToDesktop: CGRect(x: -40, y: -10, width: 140, height: 60))
        )

        XCTAssertEqual(clipped.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(clipped.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(clipped.width, 100.0 / 1440.0, accuracy: 0.000_001)
        XCTAssertEqual(clipped.height, 50.0 / 900.0, accuracy: 0.000_001)
    }

    func testClippingStillRejectsRectanglesEntirelyOffTheDesktop() {
        XCTAssertNil(mapper.normalizeAXRect(clippingToDesktop: CGRect(x: 1500, y: 10, width: 100, height: 20)))
        XCTAssertNil(mapper.normalizeAXRect(clippingToDesktop: CGRect(x: 10, y: -80, width: 100, height: 20)))
        XCTAssertNil(mapper.normalizeAXRect(clippingToDesktop: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)))
    }

    func testScreenshotMappingHandlesRetinaPixelSize() throws {
        // A 1440x900 point display captured at 2x: pixel coordinates are twice the points.
        let displayBounds = try XCTUnwrap(mapper.normalizeAXRect(CGRect(x: 0, y: 0, width: 1440, height: 900)))
        let mapped = try XCTUnwrap(
            CoordinateSpaceMapper.normalizedScreenshotRect(
                pixelRect: CGRect(x: 1440, y: 900, width: 288, height: 180),
                pixelSize: CGSize(width: 2880, height: 1800),
                displayBounds: displayBounds
            )
        )

        XCTAssertEqual(mapped.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(mapped.y, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(mapped.width, 0.1, accuracy: 0.000_001)
    }

    func testLocalSwiftUIRectInvertsYOnceForASecondaryScreen() {
        let screenFrame = CGRect(x: -1440, y: 120, width: 1440, height: 900)
        let global = CGRect(x: -1240, y: 800, width: 100, height: 40)

        let local = CoordinateSpaceMapper.localSwiftUIRect(fromGlobalAppKit: global, in: screenFrame)

        XCTAssertEqual(local.origin.x, 200, accuracy: 0.001)
        // AppKit maxY 840 is 180 points below the screen's top edge (1020).
        XCTAssertEqual(local.origin.y, 180, accuracy: 0.001)
        XCTAssertEqual(local.height, 40, accuracy: 0.001)
    }
}
