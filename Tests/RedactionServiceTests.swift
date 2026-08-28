import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Beacon

final class RedactionServiceTests: XCTestCase {
    func testRedactionCountsOnlyRegionsOnCapturedDisplay() throws {
        let snapshot = try makeSnapshot()
        let regions = [
            RedactionRegion(bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2), category: .passwordField),
            RedactionRegion(bounds: .init(x: 0.8, y: 0.1, width: 0.1, height: 0.1), category: .userDefined)
        ]
        let result = try RedactionService().redact(snapshot: snapshot, regions: regions)
        XCTAssertEqual(result.redactionCount, 1)
        XCTAssertNotEqual(result.pngData, snapshot.pngData)
    }

    private func makeSnapshot() throws -> ScreenSnapshot {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return ScreenSnapshot(
            capturedAt: Date(), displayID: 1, pixelWidth: 100, pixelHeight: 100,
            displayBounds: .init(x: 0, y: 0, width: 0.5, height: 1),
            pngData: data as Data, redactionCount: 0
        )
    }
}
