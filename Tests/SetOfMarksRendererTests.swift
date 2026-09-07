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

final class SetOfMarksBadgePlacementTests: XCTestCase {
    /// Menu bar items sit on the top edge of the capture. A badge centred on the mark's
    /// corner would be half outside the bitmap and its digit unreadable to a model.
    func testBadgeForATopEdgeMarkIsDrawnInsideTheImage() throws {
        let rendered = try render(bounds: .init(x: 0.02, y: 0, width: 0.06, height: 0.02))

        let inkedRows = try inkedRows(in: rendered)
        XCTAssertTrue(inkedRows.contains { $0 < 8 }, "Badge must reach the top edge region")
        XCTAssertTrue(
            inkedRows.allSatisfy { $0 >= 0 },
            "Nothing may be drawn outside the bitmap"
        )
        XCTAssertGreaterThan(inkedRows.count, 4, "The badge must be visible, not clipped away")
    }

    func testBadgeForALeftEdgeMarkIsDrawnInsideTheImage() throws {
        let rendered = try render(bounds: .init(x: 0, y: 0.3, width: 0.05, height: 0.1))

        let inkedColumns = try inkedColumns(in: rendered)
        XCTAssertTrue(inkedColumns.contains { $0 < 8 }, "Badge must reach the left edge region")
        XCTAssertGreaterThan(inkedColumns.count, 4)
    }

    /// A mark that belongs to another display maps to no pixels here; drawing it would
    /// place a numbered badge at the bitmap origin, pointing at unrelated content.
    func testMarkOutsideTheCapturedDisplayIsNotDrawn() throws {
        let scene = scene(
            marks: [.init(x: 0.1, y: 0.1, width: 0.05, height: 0.05)],
            displayBounds: .init(x: 0.5, y: 0, width: 0.5, height: 1)
        )
        let snapshot = try XCTUnwrap(scene.screenshot)

        let result = try SetOfMarksRenderer().render(
            scene: scene,
            marks: [SetOfMark(
                id: 1, elementID: "off", visualElementID: nil,
                bounds: .init(x: 0.1, y: 0.1, width: 0.05, height: 0.05),
                label: "Elsewhere", source: .accessibility, visualKind: nil
            )]
        )

        XCTAssertEqual(result.snapshot.pngData, snapshot.pngData, "Nothing may be drawn")
    }

    private func render(bounds: NormalizedRect) throws -> [UInt8] {
        let scene = scene(marks: [bounds], displayBounds: .init(x: 0, y: 0, width: 1, height: 1))
        let result = try SetOfMarksRenderer().render(
            scene: scene,
            marks: [SetOfMark(
                id: 7, elementID: "e", visualElementID: nil, bounds: bounds,
                label: "Target", source: .accessibility, visualKind: nil
            )]
        )
        return try pixels(of: result.snapshot)
    }

    private func inkedRows(in pixels: [UInt8]) throws -> [Int] {
        (0..<120).filter { row in
            (0..<200).contains { column in
                let index = (row * 200 + column) * 4
                // The badge fill is a saturated blue; the background is flat grey.
                return pixels[index] < 100 && pixels[index + 2] > 180
            }
        }
    }

    private func inkedColumns(in pixels: [UInt8]) throws -> [Int] {
        (0..<200).filter { column in
            (0..<120).contains { row in
                let index = (row * 200 + column) * 4
                return pixels[index] < 100 && pixels[index + 2] > 180
            }
        }
    }

    private func pixels(of snapshot: ScreenSnapshot) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(snapshot.pngData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var buffer = [UInt8](repeating: 0, count: 200 * 120 * 4)
        let context = try XCTUnwrap(CGContext(
            data: &buffer, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 200 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 120))
        return buffer
    }

    private func scene(marks: [NormalizedRect], displayBounds: NormalizedRect) -> ScreenScene {
        let context = CGContext(
            data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Fixture", bundleIdentifier: nil, processIdentifier: 1),
            activeWindow: nil,
            screenshot: ScreenSnapshot(
                capturedAt: Date(), displayID: 1, pixelWidth: 200, pixelHeight: 120,
                displayBounds: displayBounds, pngData: data as Data, redactionCount: 0
            ),
            elements: [],
            displays: []
        )
    }
}
