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
