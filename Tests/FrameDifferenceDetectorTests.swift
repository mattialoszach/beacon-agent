import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Beacon

final class FrameDifferenceDetectorTests: XCTestCase {
    func testIdenticalFramesHaveNoDifference() throws {
        let frame = try snapshot(gray: 0.4)
        XCTAssertEqual(try XCTUnwrap(FrameDifferenceDetector().difference(between: frame, and: frame)), 0, accuracy: 0.0001)
    }

    func testContrastingFramesAreMeaningfullyDifferent() throws {
        let black = try snapshot(gray: 0)
        let white = try snapshot(gray: 1)
        XCTAssertTrue(FrameDifferenceDetector().isMeaningfulChange(between: black, and: white))
        XCTAssertGreaterThan(try XCTUnwrap(FrameDifferenceDetector().difference(between: black, and: white)), 0.9)
    }

    func testUndecodableFrameCannotVerifyAnAction() throws {
        let valid = try snapshot(gray: 0.4)
        let invalid = ScreenSnapshot(
            capturedAt: Date(), displayID: 1, pixelWidth: 80, pixelHeight: 50,
            displayBounds: valid.displayBounds, pngData: Data(), redactionCount: 0
        )
        let detector = FrameDifferenceDetector()
        XCTAssertNil(detector.difference(between: valid, and: invalid))
        XCTAssertTrue(detector.isMeaningfulChange(between: valid, and: invalid),
                      "An unreadable frame must also invalidate visual target freshness.")
    }

    func testDifferentDisplaysCannotVerifyAnAction() throws {
        let valid = try snapshot(gray: 0.4)
        let other = ScreenSnapshot(
            capturedAt: Date(), displayID: 2, pixelWidth: 80, pixelHeight: 50,
            displayBounds: valid.displayBounds, pngData: valid.pngData, redactionCount: 0
        )
        XCTAssertNil(FrameDifferenceDetector().difference(between: valid, and: other))
    }

    func testComparisonStoreRecoversTheRawFrameForARedactedSnapshot() throws {
        let raw = try snapshot(gray: 1)
        let redacted = ScreenSnapshot(
            capturedAt: raw.capturedAt,
            displayID: raw.displayID,
            pixelWidth: raw.pixelWidth,
            pixelHeight: raw.pixelHeight,
            displayBounds: raw.displayBounds,
            pngData: try snapshot(gray: 0).pngData,
            redactionCount: 1
        )
        var store = FrameComparisonSampleStore()

        store.record(unredacted: raw, for: redacted)

        let baseline = try XCTUnwrap(store.comparisonSample(for: redacted))
        XCTAssertEqual(
            FrameDifferenceDetector().difference(between: baseline, and: raw),
            0
        )
    }

    private func snapshot(gray: CGFloat) throws -> ScreenSnapshot {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 80, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 50))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return ScreenSnapshot(
            capturedAt: Date(), displayID: 1, pixelWidth: 80, pixelHeight: 50,
            displayBounds: .init(x: 0, y: 0, width: 1, height: 1),
            pngData: data as Data, redactionCount: 0
        )
    }
}

final class FrameDifferenceBoundaryTests: XCTestCase {
    func testIdenticalFramesReportNoDifference() throws {
        let frame = try snapshot(gray: 0.5)

        XCTAssertEqual(FrameDifferenceDetector().difference(between: frame, and: frame), 0)
        XCTAssertFalse(FrameDifferenceDetector().isMeaningfulChange(between: frame, and: frame))
    }

    func testDifferentPixelSizesAreIncomparableRatherThanDifferent() throws {
        let first = try snapshot(gray: 0.5)
        let second = try snapshot(gray: 0.5, width: 80)

        XCTAssertNil(
            FrameDifferenceDetector().difference(between: first, and: second),
            "Incomparable frames must not report a difference"
        )
        XCTAssertTrue(
            FrameDifferenceDetector().isMeaningfulChange(between: first, and: second),
            "An incomparable pair cannot prove the screen stayed still"
        )
    }

    func testDifferentDisplaysAreIncomparable() throws {
        let first = try snapshot(gray: 0.5)
        let second = try snapshot(gray: 0.5, displayID: 2)

        XCTAssertNil(FrameDifferenceDetector().difference(between: first, and: second))
    }

    func testThresholdBoundaryIsInclusive() throws {
        let detector = FrameDifferenceDetector(meaningfulThreshold: 0.5)
        let black = try snapshot(gray: 0)
        let mid = try snapshot(gray: 0.5)

        let difference = try XCTUnwrap(detector.difference(between: black, and: mid))
        XCTAssertGreaterThan(difference, 0.5, "A black-to-mid-grey change is well past the threshold")
        XCTAssertLessThanOrEqual(difference, 1)
        XCTAssertTrue(detector.isMeaningfulChange(between: black, and: mid))
        XCTAssertFalse(
            FrameDifferenceDetector(meaningfulThreshold: 0.99)
                .isMeaningfulChange(between: black, and: mid),
            "A difference below the threshold is not meaningful"
        )
    }

    func testUndecodableDataIsIncomparable() throws {
        let valid = try snapshot(gray: 0.5)
        let corrupt = ScreenSnapshot(
            capturedAt: Date(), displayID: 1, pixelWidth: 100, pixelHeight: 100,
            displayBounds: .init(x: 0, y: 0, width: 1, height: 1),
            pngData: Data([0x00, 0x01, 0x02]), redactionCount: 0
        )

        XCTAssertNil(FrameDifferenceDetector().difference(between: valid, and: corrupt))
    }

    private func snapshot(
        gray: CGFloat,
        width: Int = 100,
        displayID: UInt32 = 1
    ) throws -> ScreenSnapshot {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 100))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return ScreenSnapshot(
            capturedAt: Date(), displayID: displayID, pixelWidth: width, pixelHeight: 100,
            displayBounds: .init(x: 0, y: 0, width: 1, height: 1),
            pngData: data as Data, redactionCount: 0
        )
    }
}
