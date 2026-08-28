import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Beacon

final class FrameDifferenceDetectorTests: XCTestCase {
    func testIdenticalFramesHaveNoDifference() throws {
        let frame = try snapshot(gray: 0.4)
        XCTAssertEqual(FrameDifferenceDetector().difference(between: frame, and: frame), 0, accuracy: 0.0001)
    }

    func testContrastingFramesAreMeaningfullyDifferent() throws {
        let black = try snapshot(gray: 0)
        let white = try snapshot(gray: 1)
        XCTAssertTrue(FrameDifferenceDetector().isMeaningfulChange(between: black, and: white))
        XCTAssertGreaterThan(FrameDifferenceDetector().difference(between: black, and: white), 0.9)
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
