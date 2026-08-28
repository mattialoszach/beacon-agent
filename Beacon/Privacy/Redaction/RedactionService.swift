import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RedactionCategory: String, Codable, CaseIterable, Sendable {
    case passwordField
    case excludedApplication
    case userDefined
    case detectedSensitiveText
}

struct RedactionRegion: Codable, Equatable, Sendable {
    let bounds: NormalizedRect
    let category: RedactionCategory
}

struct RedactionService {
    func automaticRegions(in scene: ScreenScene) -> [RedactionRegion] {
        scene.elements.compactMap { element in
            guard element.subrole == "AXSecureTextField",
                  let bounds = element.bounds else { return nil }
            return RedactionRegion(bounds: bounds, category: .passwordField)
        }
    }

    func redact(
        snapshot: ScreenSnapshot,
        regions: [RedactionRegion]
    ) throws -> ScreenSnapshot {
        let applicable = regions.filter { intersects($0.bounds, snapshot.displayBounds) }
        guard !applicable.isEmpty else { return snapshot }
        guard let source = CGImageSourceCreateWithData(snapshot.pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenCaptureError.encodingFailed
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ScreenCaptureError.encodingFailed }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        var drawnRegionCount = 0
        for region in applicable {
            guard let drawingRect = CoordinateSpaceMapper.bitmapDrawingRect(
                from: region.bounds,
                pixelSize: CGSize(width: image.width, height: image.height),
                displayBounds: snapshot.displayBounds
            ) else { continue }
            context.fill(drawingRect)
            drawnRegionCount += 1
        }

        guard let redactedImage = context.makeImage() else { throw ScreenCaptureError.encodingFailed }
        return ScreenSnapshot(
            capturedAt: snapshot.capturedAt,
            displayID: snapshot.displayID,
            pixelWidth: redactedImage.width,
            pixelHeight: redactedImage.height,
            displayBounds: snapshot.displayBounds,
            pngData: try pngData(from: redactedImage),
            redactionCount: snapshot.redactionCount + drawnRegionCount
        )
    }

    private func intersects(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Bool {
        lhs.x < rhs.x + rhs.width && lhs.x + lhs.width > rhs.x
            && lhs.y < rhs.y + rhs.height && lhs.y + lhs.height > rhs.y
    }

    private func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw ScreenCaptureError.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenCaptureError.encodingFailed }
        return data as Data
    }
}
