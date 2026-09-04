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

    func testAppIconHasTransparentRoundedCorners() throws {
        let image = try XCTUnwrap(BeaconBrandAssets.appIcon)
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let maxX = bitmap.pixelsWide - 1
        let maxY = bitmap.pixelsHigh - 1

        let cornerAlpha = [
            bitmap.colorAt(x: 0, y: 0)?.alphaComponent,
            bitmap.colorAt(x: maxX, y: 0)?.alphaComponent,
            bitmap.colorAt(x: 0, y: maxY)?.alphaComponent,
            bitmap.colorAt(x: maxX, y: maxY)?.alphaComponent
        ]

        XCTAssertTrue(cornerAlpha.allSatisfy { ($0 ?? 1) == 0 })
    }
}
