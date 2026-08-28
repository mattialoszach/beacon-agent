import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SetOfMark: Identifiable, Codable, Equatable, Sendable {
    let id: Int
    let elementID: String?
    let bounds: NormalizedRect
    let label: String
}

struct MarkedScreenScene: Equatable, Sendable {
    let snapshot: ScreenSnapshot
    let marks: [SetOfMark]
}

struct SetOfMarksRenderer: Sendable {
    func render(scene: ScreenScene, maximumMarks: Int = 80) throws -> MarkedScreenScene {
        guard let snapshot = scene.screenshot,
              let source = CGImageSourceCreateWithData(snapshot.pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenCaptureError.encodingFailed
        }

        let accessible = scene.elements
            .filter { $0.enabled && $0.bounds.map { intersects($0, snapshot.displayBounds) } == true }
            .sorted { lhs, rhs in
                if lhs.focused != rhs.focused { return lhs.focused }
                return area(lhs.bounds) > area(rhs.bounds)
            }
            .prefix(maximumMarks)
        let marks = accessible.enumerated().compactMap { offset, element -> SetOfMark? in
            guard let bounds = element.bounds else { return nil }
            return SetOfMark(id: offset + 1, elementID: element.id, bounds: bounds, label: element.bestLabel)
        }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ScreenCaptureError.encodingFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setLineWidth(max(2, CGFloat(image.width) / 900))
        context.setStrokeColor(CGColor(red: 0.05, green: 0.65, blue: 1, alpha: 1))

        for mark in marks {
            let rect = pixelRect(for: mark.bounds, snapshot: snapshot, image: image)
            context.stroke(rect)
            drawBadge(mark.id, at: CGPoint(x: rect.minX, y: rect.maxY), in: context, imageWidth: image.width)
        }

        guard let output = context.makeImage() else { throw ScreenCaptureError.encodingFailed }
        let markedSnapshot = ScreenSnapshot(
            capturedAt: snapshot.capturedAt,
            displayID: snapshot.displayID,
            pixelWidth: output.width,
            pixelHeight: output.height,
            displayBounds: snapshot.displayBounds,
            pngData: try pngData(from: output),
            redactionCount: snapshot.redactionCount
        )
        return MarkedScreenScene(snapshot: markedSnapshot, marks: marks)
    }

    private func drawBadge(_ number: Int, at point: CGPoint, in context: CGContext, imageWidth: Int) {
        let radius = max(10, CGFloat(imageWidth) / 120)
        let badge = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(CGColor(red: 0.05, green: 0.55, blue: 1, alpha: 1))
        context.fillEllipse(in: badge)

        let font = CTFontCreateWithName("SFMono-Bold" as CFString, radius * 0.95, nil)
        let text = NSAttributedString(
            string: String(number),
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1)
            ]
        )
        let line = CTLineCreateWithAttributedString(text)
        let textBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        context.textPosition = CGPoint(x: badge.midX - textBounds.width / 2, y: badge.midY - textBounds.height / 2)
        CTLineDraw(line, context)
    }

    private func pixelRect(for rect: NormalizedRect, snapshot: ScreenSnapshot, image: CGImage) -> CGRect {
        let localX = (rect.x - snapshot.displayBounds.x) / snapshot.displayBounds.width
        let localY = (rect.y - snapshot.displayBounds.y) / snapshot.displayBounds.height
        let localWidth = rect.width / snapshot.displayBounds.width
        let localHeight = rect.height / snapshot.displayBounds.height
        return CGRect(
            x: localX * Double(image.width),
            y: (1 - localY - localHeight) * Double(image.height),
            width: localWidth * Double(image.width),
            height: localHeight * Double(image.height)
        )
    }

    private func area(_ rect: NormalizedRect?) -> Double {
        guard let rect else { return 0 }
        return rect.width * rect.height
    }

    private func intersects(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Bool {
        lhs.x < rhs.x + rhs.width && lhs.x + lhs.width > rhs.x
            && lhs.y < rhs.y + rhs.height && lhs.y + lhs.height > rhs.y
    }

    private func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenCaptureError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenCaptureError.encodingFailed }
        return data as Data
    }
}

struct SetOfMarksGrounder: GroundingStrategy {
    let name = "Set of Marks"
    let marks: [SetOfMark]

    func resolve(intention: UIIntention, scene: ScreenScene) async throws -> GroundingResult {
        guard let number = intention.preferredMark,
              let mark = marks.first(where: { $0.id == number }) else { throw GroundingError.noCandidate }
        let target: GroundedTarget = mark.elementID.map {
            .accessibilityElement(elementId: $0, bounds: mark.bounds)
        } ?? .visualRegion(bounds: mark.bounds)
        return GroundingResult(target: target, confidence: 0.9, strategy: name)
    }
}
