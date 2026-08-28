import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Beacon

final class SetOfMarksRendererTests: XCTestCase {
    func testRendererAnnotatesAndPreservesElementMapping() throws {
        let snapshot = try makeSnapshot()
        let element = UIElementDescriptor(
            id: "e_export", role: "AXButton", subrole: nil, label: "Export",
            title: nil, value: nil, enabled: true, focused: true,
            bounds: .init(x: 0.5, y: 0.4, width: 0.2, height: 0.1)
        )
        let scene = ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Fixture", bundleIdentifier: nil, processIdentifier: 1),
            activeWindow: nil,
            screenshot: snapshot,
            elements: [element],
            displays: []
        )

        let result = try SetOfMarksRenderer().render(scene: scene)
        XCTAssertEqual(result.marks.count, 1)
        XCTAssertEqual(result.marks.first?.elementID, "e_export")
        XCTAssertEqual(result.marks.first?.id, 1)
        XCTAssertNotEqual(result.snapshot.pngData, snapshot.pngData)
    }

    private func makeSnapshot() throws -> ScreenSnapshot {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return ScreenSnapshot(
            capturedAt: Date(), displayID: 1, pixelWidth: 200, pixelHeight: 120,
            displayBounds: .init(x: 0, y: 0, width: 1, height: 1),
            pngData: data as Data, redactionCount: 0
        )
    }
}
