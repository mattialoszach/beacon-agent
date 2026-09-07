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

    func testFractionalPixelRedactionFullyMasksTheBoundaryPixels() throws {
        let result = try RedactionService().redact(snapshot: makeSnapshot(), regions: [
            .init(bounds: .init(x: 0.052, y: 0.107, width: 0.006, height: 0.013), category: .passwordField)
        ])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.pngData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: 100 * 100 * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let nonwhite = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }.filter { $0 < 250 }
        XCTAssertEqual(nonwhite.count, 4)
        XCTAssertTrue(nonwhite.allSatisfy { $0 < 30 }, "Boundary pixels must be fully opaque, not antialiased.")
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

final class SecureFieldRedactionTests: XCTestCase {
    func testSecureTextFieldBecomesAPasswordRegion() {
        let scene = scene(
            elements: [element(id: "pw", subrole: "AXSecureTextField", windowID: "w1")],
            secureFieldBounds: []
        )

        let regions = RedactionService().automaticRegions(in: scene)

        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.category, .passwordField)
        XCTAssertEqual(regions.first?.bounds, bounds)
    }

    func testOrdinaryTextFieldIsNotMasked() {
        let scene = scene(
            elements: [element(id: "plain", subrole: "AXTextField", windowID: "w1")],
            secureFieldBounds: []
        )

        XCTAssertTrue(RedactionService().automaticRegions(in: scene).isEmpty)
    }

    /// The focused-window filter removes elements from other windows, but the capture
    /// still covers the whole display, so those secure fields must be masked as well.
    func testSecureFieldInAnotherWindowIsStillMasked() {
        let other = NormalizedRect(x: 0.6, y: 0.6, width: 0.1, height: 0.03)
        let scene = scene(elements: [], secureFieldBounds: [other])

        let regions = RedactionService().automaticRegions(in: scene)

        XCTAssertEqual(regions.map(\.bounds), [other])
    }

    func testTheSameFieldIsNotMaskedTwice() {
        let scene = scene(
            elements: [element(id: "pw", subrole: "AXSecureTextField", windowID: "w1")],
            secureFieldBounds: [bounds]
        )

        XCTAssertEqual(RedactionService().automaticRegions(in: scene).count, 1)
    }

    private let bounds = NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.05)

    private func element(id: String, subrole: String, windowID: String) -> UIElementDescriptor {
        UIElementDescriptor(
            id: id, role: "AXTextField", subrole: subrole, label: "Password", title: nil,
            value: nil, enabled: true, focused: false, bounds: bounds, windowID: windowID
        )
    }

    private func scene(
        elements: [UIElementDescriptor],
        secureFieldBounds: [NormalizedRect]
    ) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "App", bundleIdentifier: "com.example.app", processIdentifier: 11),
            activeWindow: WindowDescriptor(title: "Main", bounds: nil, id: "w1"),
            screenshot: nil,
            elements: elements,
            displays: [],
            secureFieldBounds: secureFieldBounds
        )
    }
}
