import CoreGraphics
import Foundation

/// Beacon's canonical geometry uses a top-left origin and values in `0 ... 1`
/// across the complete virtual desktop.
struct NormalizedPoint: Codable, Equatable, Hashable, Sendable {
    let x: Double
    let y: Double

    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width >= 0 && height >= 0
            && x + width <= 1.000_001 && y + height <= 1.000_001
    }

    var center: NormalizedPoint {
        .init(x: x + width / 2, y: y + height / 2)
    }

    func insetBy(dx: Double, dy: Double) -> NormalizedRect {
        NormalizedRect(
            x: max(0, x + dx),
            y: max(0, y + dy),
            width: max(0, min(1 - max(0, x + dx), width - dx * 2)),
            height: max(0, min(1 - max(0, y + dy), height - dy * 2))
        )
    }

    static func clamped(x: Double, y: Double, width: Double, height: Double) -> NormalizedRect {
        let safeX = min(max(x.isFinite ? x : 0, 0), 1)
        let safeY = min(max(y.isFinite ? y : 0, 0), 1)
        return .init(
            x: safeX,
            y: safeY,
            width: min(max(width.isFinite ? width : 0, 0), 1 - safeX),
            height: min(max(height.isFinite ? height : 0, 0), 1 - safeY)
        )
    }
}

struct CoordinateSpaceMapper: Equatable, Sendable {
    /// Quartz/AX virtual desktop bounds, expressed in logical points with a top-left origin.
    let virtualDesktopBounds: CGRect
    /// The top edge of the AppKit main screen, used for AppKit's bottom-left conversion.
    let appKitMainScreenMaxY: CGFloat

    init(virtualDesktopBounds: CGRect, appKitMainScreenMaxY: CGFloat) {
        self.virtualDesktopBounds = virtualDesktopBounds
        self.appKitMainScreenMaxY = appKitMainScreenMaxY
    }

    func normalizeAXRect(_ rect: CGRect) -> NormalizedRect? {
        guard virtualDesktopBounds.width > 0, virtualDesktopBounds.height > 0,
              rect.width >= 0, rect.height >= 0 else { return nil }

        let result = NormalizedRect(
            x: (rect.minX - virtualDesktopBounds.minX) / virtualDesktopBounds.width,
            y: (rect.minY - virtualDesktopBounds.minY) / virtualDesktopBounds.height,
            width: rect.width / virtualDesktopBounds.width,
            height: rect.height / virtualDesktopBounds.height
        )
        return result.isValid ? result : nil
    }

    func axRect(from rect: NormalizedRect) -> CGRect? {
        guard rect.isValid else { return nil }
        return CGRect(
            x: virtualDesktopBounds.minX + rect.x * virtualDesktopBounds.width,
            y: virtualDesktopBounds.minY + rect.y * virtualDesktopBounds.height,
            width: rect.width * virtualDesktopBounds.width,
            height: rect.height * virtualDesktopBounds.height
        )
    }

    func appKitRect(from rect: NormalizedRect) -> CGRect? {
        guard let ax = axRect(from: rect) else { return nil }
        return CGRect(
            x: ax.minX,
            y: appKitMainScreenMaxY - ax.maxY,
            width: ax.width,
            height: ax.height
        )
    }

    func normalizedScreenshotRect(
        pixelRect: CGRect,
        pixelSize: CGSize,
        displayBounds: NormalizedRect
    ) -> NormalizedRect? {
        guard pixelSize.width > 0, pixelSize.height > 0, displayBounds.isValid else { return nil }
        let local = NormalizedRect(
            x: pixelRect.minX / pixelSize.width,
            y: pixelRect.minY / pixelSize.height,
            width: pixelRect.width / pixelSize.width,
            height: pixelRect.height / pixelSize.height
        )
        guard local.isValid else { return nil }
        return NormalizedRect(
            x: displayBounds.x + local.x * displayBounds.width,
            y: displayBounds.y + local.y * displayBounds.height,
            width: local.width * displayBounds.width,
            height: local.height * displayBounds.height
        )
    }
}
