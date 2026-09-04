import AppKit
import XCTest
@testable import Beacon

final class BeaconBrandAssetsTests: XCTestCase {
    func testBrandImagesAreBundled() {
        XCTAssertNotNil(BeaconBrandAssets.appIcon)
        XCTAssertNotNil(BeaconBrandAssets.logo)
        XCTAssertEqual(BeaconBrandAssets.logo?.isTemplate, true)
        XCTAssertEqual(BeaconBrandAssets.menuBarLogo?.isTemplate, true)
        XCTAssertEqual(BeaconBrandAssets.menuBarLogo?.size.height, 14)
        XCTAssertLessThanOrEqual(BeaconBrandAssets.menuBarLogo?.size.width ?? .infinity, 18)
    }

    func testAppIconUsesPaddedHighResolutionArtwork() throws {
        let image = try XCTUnwrap(BeaconBrandAssets.appIcon)
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))

        XCTAssertEqual(bitmap.pixelsWide, 1_024)
        XCTAssertEqual(bitmap.pixelsHigh, 1_024)
        XCTAssertTrue(bitmap.hasAlpha)

        let maxX = bitmap.pixelsWide - 1
        let maxY = bitmap.pixelsHigh - 1
        let midX = maxX / 2
        let midY = maxY / 2
        let outerEdgeAlpha = [
            bitmap.colorAt(x: midX, y: 0)?.alphaComponent,
            bitmap.colorAt(x: midX, y: maxY)?.alphaComponent,
            bitmap.colorAt(x: 0, y: midY)?.alphaComponent,
            bitmap.colorAt(x: maxX, y: midY)?.alphaComponent
        ]

        XCTAssertTrue(outerEdgeAlpha.allSatisfy { ($0 ?? 1) == 0 })
    }
}
