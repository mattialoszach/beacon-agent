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

    func difference(between first: ScreenSnapshot, and second: ScreenSnapshot) -> Double {
        guard first.displayID == second.displayID,
              let lhs = samples(from: first.pngData),
              let rhs = samples(from: second.pngData),
              lhs.count == rhs.count else { return 1 }
        let total = zip(lhs, rhs).reduce(0.0) { partial, pair in
            partial + abs(Double(pair.0) - Double(pair.1)) / 255
        }
        return total / Double(max(1, lhs.count))
    }

    func isMeaningfulChange(between first: ScreenSnapshot, and second: ScreenSnapshot) -> Bool {
        difference(between: first, and: second) >= meaningfulThreshold
    }

    private func samples(from data: Data) -> [UInt8]? {
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
