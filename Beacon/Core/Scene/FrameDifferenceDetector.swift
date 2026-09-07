import CoreGraphics
import Foundation
import ImageIO

struct FrameDifferenceDetector: Sendable {
    let sampleWidth: Int
    let sampleHeight: Int
    let meaningfulThreshold: Double

    init(sampleWidth: Int = 64, sampleHeight: Int = 40, meaningfulThreshold: Double = 0.035) {
        self.sampleWidth = sampleWidth
        self.sampleHeight = sampleHeight
        self.meaningfulThreshold = meaningfulThreshold
    }

    /// Nil means the samples are incomparable, not evidence of a successful action.
    func difference(between first: ScreenSnapshot, and second: ScreenSnapshot) -> Double? {
        guard let lhs = sample(from: first), let rhs = sample(from: second) else { return nil }
        return difference(between: lhs, and: rhs)
    }

    func difference(between first: FrameDifferenceSample, and second: ScreenSnapshot) -> Double? {
        guard let second = sample(from: second) else { return nil }
        return difference(between: first, and: second)
    }

    func sample(from snapshot: ScreenSnapshot) -> FrameDifferenceSample? {
        guard let luminance = samples(from: snapshot.pngData) else { return nil }
        return FrameDifferenceSample(
            displayID: snapshot.displayID,
            displayBounds: snapshot.displayBounds,
            pixelWidth: snapshot.pixelWidth,
            pixelHeight: snapshot.pixelHeight,
            sampleWidth: sampleWidth,
            sampleHeight: sampleHeight,
            luminance: luminance
        )
    }

    private func difference(
        between first: FrameDifferenceSample,
        and second: FrameDifferenceSample
    ) -> Double? {
        guard first.displayID == second.displayID,
              first.displayBounds == second.displayBounds,
              first.pixelWidth == second.pixelWidth,
              first.pixelHeight == second.pixelHeight,
              first.sampleWidth == second.sampleWidth,
              first.sampleHeight == second.sampleHeight,
              first.luminance.count == second.luminance.count else { return nil }
        let total = zip(first.luminance, second.luminance).reduce(0.0) { partial, pair in
            partial + abs(Double(pair.0) - Double(pair.1)) / 255
        }
        return total / Double(max(1, first.luminance.count))
    }

    func isMeaningfulChange(between first: ScreenSnapshot, and second: ScreenSnapshot) -> Bool {
        guard let difference = difference(between: first, and: second) else { return true }
        return difference >= meaningfulThreshold
    }

    private func samples(from data: Data) -> [UInt8]? {
        guard (1...4_096).contains(sampleWidth), (1...4_096).contains(sampleHeight) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        var grayscale: [UInt8] = []
        grayscale.reserveCapacity(sampleWidth * sampleHeight)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let value = (Int(pixels[index]) * 54 + Int(pixels[index + 1]) * 183 + Int(pixels[index + 2]) * 19) / 256
            grayscale.append(UInt8(clamping: value))
        }
        return grayscale
    }
}

struct FrameDifferenceSample: Equatable, Sendable {
    let displayID: UInt32
    let displayBounds: NormalizedRect
    let pixelWidth: Int
    let pixelHeight: Int
    let sampleWidth: Int
    let sampleHeight: Int
    let luminance: [UInt8]
}

/// Associates a privacy-filtered screenshot with a tiny luminance sample of the unredacted
/// frame captured at the same instant. The sample is only used for local change detection;
/// it never becomes part of a `ScreenScene` or provider request.
struct FrameComparisonSampleStore: Sendable {
    private let maximumSamples: Int
    private var samples: [SampleKey: FrameDifferenceSample] = [:]
    private var insertionOrder: [SampleKey] = []

    init(maximumSamples: Int = 4) {
        self.maximumSamples = max(1, maximumSamples)
    }

    mutating func record(unredacted: ScreenSnapshot, for filtered: ScreenSnapshot) {
        guard unredacted.displayID == filtered.displayID,
              unredacted.pixelWidth == filtered.pixelWidth,
              unredacted.pixelHeight == filtered.pixelHeight,
              unredacted.displayBounds == filtered.displayBounds else { return }
        guard let sample = FrameDifferenceDetector().sample(from: unredacted) else { return }
        let key = SampleKey(filtered)
        insertionOrder.removeAll(where: { $0 == key })
        insertionOrder.append(key)
        samples[key] = sample
        while insertionOrder.count > maximumSamples {
            samples.removeValue(forKey: insertionOrder.removeFirst())
        }
    }

    func comparisonSample(for filtered: ScreenSnapshot) -> FrameDifferenceSample? {
        samples[SampleKey(filtered)]
    }

    mutating func removeAll() {
        samples.removeAll()
        insertionOrder.removeAll()
    }

    private struct SampleKey: Hashable, Sendable {
        let capturedAt: Date
        let displayID: UInt32
        let pixelWidth: Int
        let pixelHeight: Int

        init(_ snapshot: ScreenSnapshot) {
            capturedAt = snapshot.capturedAt
            displayID = snapshot.displayID
            pixelWidth = snapshot.pixelWidth
            pixelHeight = snapshot.pixelHeight
        }
    }
}
