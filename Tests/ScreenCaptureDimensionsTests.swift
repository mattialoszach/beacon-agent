import XCTest
@testable import Beacon

final class ScreenCaptureDimensionsTests: XCTestCase {
    func testLargeCaptureIsDownsampledWithoutChangingAspectRatio() {
        let dimensions = ScreenCaptureDimensions.fitting(
            pixelWidth: 3_456,
            pixelHeight: 2_234,
            maximumDimension: 1_920
        )

        XCTAssertEqual(dimensions, ScreenCaptureDimensions(width: 1_920, height: 1_241))
        XCTAssertEqual(
            Double(dimensions.width) / Double(dimensions.height),
            3_456.0 / 2_234.0,
            accuracy: 0.001
        )
    }

    func testSmallCaptureKeepsNativeDimensions() {
        XCTAssertEqual(
            ScreenCaptureDimensions.fitting(
                pixelWidth: 1_280,
                pixelHeight: 720,
                maximumDimension: 1_920
            ),
            ScreenCaptureDimensions(width: 1_280, height: 720)
        )
    }
}

final class RetinaCaptureDimensionsTests: XCTestCase {
    /// SCDisplay reports points and SCStreamConfiguration expects pixels. Passing points
    /// through captured every Retina display at 1x and blurred small text for OCR.
    func testRetinaPanelIsCappedFromItsPixelSizeNotItsPointSize() {
        // MacBook Pro 14": 1512x982 points, 3024x1964 backing pixels.
        let fromPixels = ScreenCaptureDimensions.fitting(
            pixelWidth: 3_024, pixelHeight: 1_964, maximumDimension: 1_920
        )
        XCTAssertEqual(fromPixels.width, 1_920)
        XCTAssertEqual(fromPixels.height, 1_247)

        let fromPoints = ScreenCaptureDimensions.fitting(
            pixelWidth: 1_512, pixelHeight: 982, maximumDimension: 1_920
        )
        XCTAssertEqual(fromPoints.width, 1_512, "Points are below the cap, so nothing is scaled")
        XCTAssertLessThan(
            fromPoints.width, fromPixels.width,
            "Using points would give up available resolution on a Retina display"
        )
    }

    func testAspectRatioIsPreservedWhenScalingDown() {
        let scaled = ScreenCaptureDimensions.fitting(
            pixelWidth: 5_120, pixelHeight: 2_880, maximumDimension: 1_920
        )
        XCTAssertEqual(scaled.width, 1_920)
        XCTAssertEqual(
            Double(scaled.width) / Double(scaled.height),
            5_120.0 / 2_880.0,
            accuracy: 0.01
        )
    }
}
