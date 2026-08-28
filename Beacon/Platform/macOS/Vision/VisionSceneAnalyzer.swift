import CoreGraphics
import Foundation
import ImageIO
import Vision

enum VisionAnalysisError: LocalizedError {
    case invalidImage

    var errorDescription: String? { "Beacon could not analyze the captured image." }
}

struct VisionSceneAnalyzer: Sendable {
    func analyze(snapshot: ScreenSnapshot) async throws -> [VisualElementDescriptor] {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(snapshot.pngData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw VisionAnalysisError.invalidImage
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.008
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])

            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let box = observation.boundingBox
                let localTopY = 1 - box.maxY
                let paddingX = min(0.006, 8 / Double(max(1, snapshot.pixelWidth)))
                let paddingY = min(0.006, 6 / Double(max(1, snapshot.pixelHeight)))
                let localX = max(0, box.minX - paddingX)
                let localY = max(0, localTopY - paddingY)
                let localWidth = min(1 - localX, box.width + paddingX * 2)
                let localHeight = min(1 - localY, box.height + paddingY * 2)
                let bounds = NormalizedRect.clamped(
                    x: snapshot.displayBounds.x + localX * snapshot.displayBounds.width,
                    y: snapshot.displayBounds.y + localY * snapshot.displayBounds.height,
                    width: localWidth * snapshot.displayBounds.width,
                    height: localHeight * snapshot.displayBounds.height
                )
                var hasher = Hasher()
                hasher.combine(text)
                hasher.combine(Int(bounds.x * 10_000))
                hasher.combine(Int(bounds.y * 10_000))
                return VisualElementDescriptor(
                    id: "v_\(String(UInt(bitPattern: hasher.finalize()), radix: 16).suffix(10))",
                    text: String(text.prefix(300)),
                    bounds: bounds,
                    confidence: Double(candidate.confidence)
                )
            }
        }.value
    }
}
