import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SetOfMarkSource: String, Codable, Equatable, Sendable {
    case accessibility
    case visionText
    case visualShape
}

struct SetOfMark: Identifiable, Codable, Equatable, Sendable {
    let id: Int
    let elementID: String?
    let visualElementID: String?
    let bounds: NormalizedRect
    let label: String
    let source: SetOfMarkSource
    let visualKind: VisualElementKind?
}

struct MarkedScreenScene: Equatable, Sendable {
    let snapshot: ScreenSnapshot
    let marks: [SetOfMark]
}

struct SetOfMarksBuilder: Sendable {
    func build(scene: ScreenScene, maximumMarks: Int = 80, query: String? = nil) -> [SetOfMark] {
        guard maximumMarks > 0 else { return [] }
        let viewport = scene.screenshot?.displayBounds ?? scene.activeWindow?.bounds
        let accessible = scene.elements
            .filter { element in
                guard element.enabled, let bounds = element.bounds, bounds.isValid else { return false }
                return viewport.map { visible($0, contains: bounds) } != false
            }
            .sorted { accessibilityOrder($0, $1, query: query) }

        let accessibilityBounds = accessible.compactMap(\.bounds)
        let visual = scene.visualElements
            .filter { element in
                element.bounds.isValid
                    && viewport.map { visible($0, contains: element.bounds) } != false
                    && !accessibilityBounds.contains(where: { overlapRatio($0, element.bounds) > 0.58 })
            }
            .sorted { visualOrder($0, $1, query: query) }

        let desiredVisualCount = max(maximumMarks >= 24 ? 12 : 1, maximumMarks / 3)
        let maximumVisualCount = accessible.isEmpty ? maximumMarks : max(0, maximumMarks - 1)
        let reservedVisualCount = visual.isEmpty
            ? 0
            : min(visual.count, min(maximumVisualCount, desiredVisualCount))
        let initialAccessibilityCount = min(accessible.count, maximumMarks - reservedVisualCount)
        var selectedAccessibility = Array(accessible.prefix(initialAccessibilityCount))
        var selectedVisual = Array(visual.prefix(maximumMarks - selectedAccessibility.count))

        if selectedAccessibility.count + selectedVisual.count < maximumMarks {
            let remaining = maximumMarks - selectedAccessibility.count - selectedVisual.count
            selectedAccessibility += accessible.dropFirst(selectedAccessibility.count).prefix(remaining)
        }
        if selectedAccessibility.count + selectedVisual.count < maximumMarks {
            let remaining = maximumMarks - selectedAccessibility.count - selectedVisual.count
            selectedVisual += visual.dropFirst(selectedVisual.count).prefix(remaining)
        }

        let accessibilityMarks = selectedAccessibility.compactMap { element -> SetOfMark? in
            guard let bounds = element.bounds else { return nil }
            return SetOfMark(
                id: 0,
                elementID: element.id,
                visualElementID: nil,
                bounds: bounds,
                label: element.bestLabel,
                source: .accessibility,
                visualKind: nil
            )
        }
        let visualMarks = selectedVisual.map { element in
            SetOfMark(
                id: 0,
                elementID: nil,
                visualElementID: element.id,
                bounds: element.bounds,
                label: element.bestLabel,
                source: element.kind == .text ? .visionText : .visualShape,
                visualKind: element.kind
            )
        }
        return (accessibilityMarks + visualMarks).enumerated().map { offset, mark in
            SetOfMark(
                id: offset + 1,
                elementID: mark.elementID,
                visualElementID: mark.visualElementID,
                bounds: mark.bounds,
                label: mark.label,
                source: mark.source,
                visualKind: mark.visualKind
            )
        }
    }

    private func accessibilityOrder(
        _ lhs: UIElementDescriptor,
        _ rhs: UIElementDescriptor,
        query: String?
    ) -> Bool {
        let lhsQueryScore = query.map { SemanticElementMatcher.relevanceScore(query: $0, candidate: lhs.bestLabel) } ?? 0
        let rhsQueryScore = query.map { SemanticElementMatcher.relevanceScore(query: $0, candidate: rhs.bestLabel) } ?? 0
        if lhsQueryScore != rhsQueryScore { return lhsQueryScore > rhsQueryScore }
        if lhs.focused != rhs.focused { return lhs.focused }
        let lhsLabelled = lhs.bestLabel != "Unlabelled control"
        let rhsLabelled = rhs.bestLabel != "Unlabelled control"
        if lhsLabelled != rhsLabelled { return lhsLabelled }
        let lhsArea = lhs.bounds.map { $0.width * $0.height } ?? 0
        let rhsArea = rhs.bounds.map { $0.width * $0.height } ?? 0
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        return lhs.id < rhs.id
    }

    private func visualOrder(
        _ lhs: VisualElementDescriptor,
        _ rhs: VisualElementDescriptor,
        query: String?
    ) -> Bool {
        let lhsQueryScore = queryPriority(for: lhs, query: query)
        let rhsQueryScore = queryPriority(for: rhs, query: query)
        if lhsQueryScore != rhsQueryScore { return lhsQueryScore > rhsQueryScore }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id < rhs.id
    }

    private func queryPriority(for element: VisualElementDescriptor, query: String?) -> Double {
        guard let query else { return 0 }
        let normalized = query.lowercased()
        var score = SemanticElementMatcher.relevanceScore(query: query, candidate: element.bestLabel)
        if element.kind == .circle, normalized.contains("circle") || normalized.contains("round") { score += 0.5 }
        if element.kind == .rectangle,
           normalized.contains("rectangle") || normalized.contains("square") || normalized.contains("box") {
            score += 0.5
        }
        if element.kind == .icon, normalized.contains("icon") || normalized.contains("symbol") { score += 0.5 }
        if element.kind == .canvasShape,
           normalized.contains("shape") || normalized.contains("object") || normalized.contains("drawing") {
            score += 0.5
        }
        if normalized.contains("left"), element.bounds.center.x <= 0.42 { score += 0.1 }
        if normalized.contains("right"), element.bounds.center.x >= 0.58 { score += 0.1 }
        if normalized.contains("top"), element.bounds.center.y <= 0.42 { score += 0.1 }
        if normalized.contains("bottom"), element.bounds.center.y >= 0.58 { score += 0.1 }
        return score
    }

    private func visible(_ viewport: NormalizedRect, contains bounds: NormalizedRect) -> Bool {
        viewport.x < bounds.x + bounds.width && viewport.x + viewport.width > bounds.x
            && viewport.y < bounds.y + bounds.height && viewport.y + viewport.height > bounds.y
    }

    private func overlapRatio(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let intersectionWidth = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
        let intersectionHeight = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
        let intersection = intersectionWidth * intersectionHeight
        return intersection / max(0.000_000_1, min(lhs.width * lhs.height, rhs.width * rhs.height))
    }
}

struct SetOfMarksRenderer: Sendable {
    func render(scene: ScreenScene, maximumMarks: Int = 80) throws -> MarkedScreenScene {
        try render(scene: scene, marks: SetOfMarksBuilder().build(scene: scene, maximumMarks: maximumMarks))
    }

    func render(scene: ScreenScene, marks: [SetOfMark]) throws -> MarkedScreenScene {
        guard let snapshot = scene.screenshot,
              let source = CGImageSourceCreateWithData(snapshot.pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenCaptureError.encodingFailed
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
        CoordinateSpaceMapper.bitmapDrawingRect(
            from: rect,
            pixelSize: CGSize(width: image.width, height: image.height),
            displayBounds: snapshot.displayBounds
        ) ?? .zero
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

enum SetOfMarksMatcher {
    struct Match: Equatable, Sendable {
        let mark: SetOfMark
        let score: Double
    }

    static func bestMatch(for question: String, in marks: [SetOfMark]) -> Match? {
        let query = question.lowercased()
        let requestedKinds = requestedVisualKinds(in: query)
        return marks.compactMap { mark -> Match? in
            var score = SemanticElementMatcher.relevanceScore(query: question, candidate: mark.label)
            if let kind = mark.visualKind, requestedKinds.contains(kind) {
                score = max(score, 0.66)
            }
            score += spatialScore(query: query, bounds: mark.bounds)
            if mark.source == .accessibility, score > 0 { score += 0.04 }
            guard score >= 0.45 else { return nil }
            return Match(mark: mark, score: min(0.96, score))
        }
        .max {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.mark.id > $1.mark.id
        }
    }

    private static func requestedVisualKinds(in query: String) -> Set<VisualElementKind> {
        var kinds = Set<VisualElementKind>()
        if query.contains("circle") || query.contains("round") { kinds.insert(.circle) }
        if query.contains("rectangle") || query.contains("box") || query.contains("square") { kinds.insert(.rectangle) }
        if query.contains("icon") || query.contains("symbol") { kinds.insert(.icon) }
        if query.contains("shape") || query.contains("object") || query.contains("drawing") { kinds.insert(.canvasShape) }
        return kinds
    }

    private static func spatialScore(query: String, bounds: NormalizedRect) -> Double {
        var score = 0.0
        if query.contains("left"), bounds.center.x <= 0.42 { score += 0.12 }
        if query.contains("right"), bounds.center.x >= 0.58 { score += 0.12 }
        if query.contains("top"), bounds.center.y <= 0.42 { score += 0.12 }
        if query.contains("bottom"), bounds.center.y >= 0.58 { score += 0.12 }
        if query.contains("center") || query.contains("middle") {
            let distance = abs(bounds.center.x - 0.5) + abs(bounds.center.y - 0.5)
            if distance <= 0.3 { score += 0.12 }
        }
        return score
    }
}
