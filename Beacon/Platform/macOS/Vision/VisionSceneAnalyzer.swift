import CoreGraphics
import Foundation
import ImageIO
import Vision

enum VisionAnalysisError: LocalizedError {
    case invalidImage

    var errorDescription: String? { "Beacon could not analyze the captured image." }
}

struct VisualShapeClassification: Equatable, Sendable {
    let kind: VisualElementKind
    let confidence: Double
}

enum VisualShapeClassifier {
    static func classify(
        points: [CGPoint],
        imageSize: CGSize,
        simplifiedPointCount: Int? = nil
    ) -> VisualShapeClassification? {
        guard points.count >= 4,
              imageSize.width > 0,
              imageSize.height > 0 else { return nil }
        let pixelPoints = points.map {
            CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height)
        }
        let xs = pixelPoints.map(\.x)
        let ys = pixelPoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = maxX - minX
        let height = maxY - minY
        let boundingArea = width * height
        let imageArea = imageSize.width * imageSize.height
        guard width >= 8, height >= 8, boundingArea >= 80,
              width <= imageSize.width * 0.72,
              height <= imageSize.height * 0.72,
              boundingArea <= imageArea * 0.32 else { return nil }

        let closedPoints = pixelPoints.dropFirst() + [pixelPoints[0]]
        let perimeter = zip(pixelPoints, closedPoints).reduce(0.0) { result, pair in
            result + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
        let signedArea = zip(pixelPoints, closedPoints).reduce(0.0) { result, pair in
            result + pair.0.x * pair.1.y - pair.1.x * pair.0.y
        } / 2
        let area = abs(signedArea)
        guard perimeter > 0, area >= 30 else { return nil }
        let circularity = min(1, 4 * Double.pi * area / (perimeter * perimeter))
        let aspect = width / height

        if let simplifiedPointCount, (4...6).contains(simplifiedPointCount), circularity >= 0.45 {
            return VisualShapeClassification(kind: .rectangle, confidence: min(0.9, 0.58 + circularity * 0.24))
        }
        if (0.72...1.38).contains(aspect), circularity >= 0.72 {
            return VisualShapeClassification(kind: .circle, confidence: min(0.94, 0.62 + circularity * 0.32))
        }

        let areaFraction = boundingArea / imageArea
        if areaFraction <= 0.006 {
            return VisualShapeClassification(kind: .icon, confidence: 0.62)
        }
        return VisualShapeClassification(kind: .canvasShape, confidence: 0.58)
    }
}

struct VisionSceneAnalyzer: Sendable {
    func analyze(snapshot: ScreenSnapshot) async throws -> [VisualElementDescriptor] {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(snapshot.pngData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw VisionAnalysisError.invalidImage
            }

            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.minimumTextHeight = 0.008

            let rectangleRequest = VNDetectRectanglesRequest()
            rectangleRequest.minimumAspectRatio = 0.08
            rectangleRequest.maximumAspectRatio = 1
            rectangleRequest.quadratureTolerance = 18
            rectangleRequest.minimumSize = 0.01
            rectangleRequest.minimumConfidence = 0.45
            rectangleRequest.maximumObservations = 80

            let darkContourRequest = contourRequest(detectsDarkOnLight: true)
            let lightContourRequest = contourRequest(detectsDarkOnLight: false)
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([
                textRequest,
                rectangleRequest,
                darkContourRequest,
                lightContourRequest
            ])

            let textElements = (textRequest.results ?? []).compactMap { observation -> VisualElementDescriptor? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                guard let bounds = mappedBounds(
                    observation.boundingBox,
                    snapshot: snapshot,
                    paddingX: min(0.006, 8 / Double(max(1, snapshot.pixelWidth))),
                    paddingY: min(0.006, 6 / Double(max(1, snapshot.pixelHeight)))
                ) else { return nil }
                return descriptor(
                    text: String(text.prefix(300)),
                    bounds: bounds,
                    confidence: Double(candidate.confidence),
                    kind: .text
                )
            }

            let rectangles = (rectangleRequest.results ?? []).compactMap { observation -> VisualElementDescriptor? in
                guard let bounds = mappedBounds(observation.boundingBox, snapshot: snapshot) else { return nil }
                guard isUseful(bounds: bounds, snapshot: snapshot) else { return nil }
                return shapeDescriptor(
                    kind: .rectangle,
                    bounds: bounds,
                    confidence: max(0.55, Double(observation.confidence)),
                    nearbyText: textElements
                )
            }

            let contourElements = [darkContourRequest, lightContourRequest]
                .flatMap { $0.results ?? [] }
                .flatMap { observation in
                    contours(in: observation).compactMap { contour -> VisualElementDescriptor? in
                        let normalizedPoints = contour.normalizedPoints.map {
                            CGPoint(x: CGFloat($0.x), y: CGFloat($0.y))
                        }
                        let simplifiedCount = (try? contour.polygonApproximation(epsilon: 0.012))?.pointCount
                        guard let classification = VisualShapeClassifier.classify(
                            points: normalizedPoints,
                            imageSize: CGSize(width: image.width, height: image.height),
                            simplifiedPointCount: simplifiedCount
                        ), let visionBounds = boundingBox(of: normalizedPoints) else { return nil }
                        guard let bounds = mappedBounds(visionBounds, snapshot: snapshot) else { return nil }
                        return shapeDescriptor(
                            kind: classification.kind,
                            bounds: bounds,
                            confidence: classification.confidence,
                            nearbyText: textElements
                        )
                    }
                }

            let shapes = deduplicated(rectangles + contourElements)
                .sorted {
                    if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                    return $0.id < $1.id
                }
                .prefix(120)
            return textElements + shapes
        }.value
    }
}

private func contourRequest(detectsDarkOnLight: Bool) -> VNDetectContoursRequest {
    let request = VNDetectContoursRequest()
    request.contrastAdjustment = 1.4
    request.detectsDarkOnLight = detectsDarkOnLight
    request.maximumImageDimension = 1_024
    return request
}

private func contours(in observation: VNContoursObservation) -> [VNContour] {
    (0..<min(observation.contourCount, 320)).compactMap { index in
        try? observation.contour(at: index)
    }
}

private func boundingBox(of points: [CGPoint]) -> CGRect? {
    guard let first = points.first else { return nil }
    return points.dropFirst().reduce(CGRect(x: first.x, y: first.y, width: 0, height: 0)) {
        $0.union(CGRect(x: $1.x, y: $1.y, width: 0, height: 0))
    }
}

private func mappedBounds(
    _ visionBounds: CGRect,
    snapshot: ScreenSnapshot,
    paddingX: Double = 0,
    paddingY: Double = 0
) -> NormalizedRect? {
    CoordinateSpaceMapper.normalizedBottomLeftImageRect(
        visionBounds,
        pixelSize: CGSize(width: snapshot.pixelWidth, height: snapshot.pixelHeight),
        displayBounds: snapshot.displayBounds,
        paddingX: paddingX,
        paddingY: paddingY
    )
}

private func isUseful(bounds: NormalizedRect, snapshot: ScreenSnapshot) -> Bool {
    let relativeWidth = bounds.width / snapshot.displayBounds.width
    let relativeHeight = bounds.height / snapshot.displayBounds.height
    let area = relativeWidth * relativeHeight
    return bounds.isValid && relativeWidth >= 0.006 && relativeHeight >= 0.006
        && relativeWidth <= 0.72 && relativeHeight <= 0.72 && area <= 0.32
}

private func shapeDescriptor(
    kind: VisualElementKind,
    bounds: NormalizedRect,
    confidence: Double,
    nearbyText: [VisualElementDescriptor]
) -> VisualElementDescriptor {
    let nearby = nearbyText
        .filter { contains(bounds, point: $0.bounds.center) || distance(from: bounds, to: $0.bounds) <= 0.018 }
        .min { distance(from: bounds, to: $0.bounds) < distance(from: bounds, to: $1.bounds) }
    let label = nearby.map { "\($0.text) \(kind.displayName.lowercased()) control" } ?? kind.displayName
    return descriptor(text: label, bounds: bounds, confidence: confidence, kind: kind)
}

private func descriptor(
    text: String,
    bounds: NormalizedRect,
    confidence: Double,
    kind: VisualElementKind
) -> VisualElementDescriptor {
    var hasher = Hasher()
    hasher.combine(kind)
    hasher.combine(text)
    hasher.combine(Int(bounds.x * 10_000))
    hasher.combine(Int(bounds.y * 10_000))
    hasher.combine(Int(bounds.width * 10_000))
    hasher.combine(Int(bounds.height * 10_000))
    return VisualElementDescriptor(
        id: "v_\(String(UInt(bitPattern: hasher.finalize()), radix: 16).suffix(10))",
        text: text,
        bounds: bounds,
        confidence: min(1, max(0, confidence)),
        kind: kind
    )
}

private func deduplicated(_ elements: [VisualElementDescriptor]) -> [VisualElementDescriptor] {
    elements
        .sorted { $0.confidence > $1.confidence }
        .reduce(into: []) { result, element in
            guard !result.contains(where: {
                $0.kind == element.kind && overlapRatio($0.bounds, element.bounds) >= 0.76
            }) else { return }
            result.append(element)
        }
}

private func contains(_ bounds: NormalizedRect, point: NormalizedPoint) -> Bool {
    point.x >= bounds.x && point.x <= bounds.x + bounds.width
        && point.y >= bounds.y && point.y <= bounds.y + bounds.height
}

private func distance(from lhs: NormalizedRect, to rhs: NormalizedRect) -> Double {
    hypot(lhs.center.x - rhs.center.x, lhs.center.y - rhs.center.y)
}

private func overlapRatio(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
    let width = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
    let height = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
    let intersection = width * height
    return intersection / max(0.000_000_1, min(lhs.width * lhs.height, rhs.width * rhs.height))
}
