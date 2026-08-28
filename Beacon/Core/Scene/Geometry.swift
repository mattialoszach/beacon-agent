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
        Self.normalizedScreenshotRect(
            pixelRect: pixelRect,
            pixelSize: pixelSize,
            displayBounds: displayBounds
        )
    }

    static func normalizedScreenshotRect(
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

    static func screenshotPixelRect(
        from rect: NormalizedRect,
        pixelSize: CGSize,
        displayBounds: NormalizedRect
    ) -> CGRect? {
        guard rect.isValid, displayBounds.isValid,
              displayBounds.width > 0, displayBounds.height > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let clippedMinX = max(rect.x, displayBounds.x)
        let clippedMinY = max(rect.y, displayBounds.y)
        let clippedMaxX = min(rect.x + rect.width, displayBounds.x + displayBounds.width)
        let clippedMaxY = min(rect.y + rect.height, displayBounds.y + displayBounds.height)
        guard clippedMaxX > clippedMinX, clippedMaxY > clippedMinY else { return nil }
        let clipped = NormalizedRect(
            x: clippedMinX,
            y: clippedMinY,
            width: clippedMaxX - clippedMinX,
            height: clippedMaxY - clippedMinY
        )
        let local = NormalizedRect(
            x: (clipped.x - displayBounds.x) / displayBounds.width,
            y: (clipped.y - displayBounds.y) / displayBounds.height,
            width: clipped.width / displayBounds.width,
            height: clipped.height / displayBounds.height
        )
        guard local.isValid else { return nil }
        return CGRect(
            x: local.x * pixelSize.width,
            y: local.y * pixelSize.height,
            width: local.width * pixelSize.width,
            height: local.height * pixelSize.height
        )
    }

    /// Maps a normalized image-analysis rectangle with a bottom-left origin into
    /// Beacon's top-left virtual-desktop coordinate space.
    static func normalizedBottomLeftImageRect(
        _ rect: CGRect,
        pixelSize: CGSize,
        displayBounds: NormalizedRect,
        paddingX: Double = 0,
        paddingY: Double = 0
    ) -> NormalizedRect? {
        let localTopY = 1 - rect.maxY
        let localX = max(0, rect.minX - paddingX)
        let localY = max(0, localTopY - paddingY)
        let localWidth = min(1 - localX, rect.width + paddingX * 2)
        let localHeight = min(1 - localY, rect.height + paddingY * 2)
        return normalizedScreenshotRect(
            pixelRect: CGRect(
                x: localX * pixelSize.width,
                y: localY * pixelSize.height,
                width: localWidth * pixelSize.width,
                height: localHeight * pixelSize.height
            ),
            pixelSize: pixelSize,
            displayBounds: displayBounds
        )
    }

    /// Maps Beacon geometry into Core Graphics bitmap coordinates, whose origin is
    /// at the bottom-left for the drawing contexts used by redaction and marks.
    static func bitmapDrawingRect(
        from rect: NormalizedRect,
        pixelSize: CGSize,
        displayBounds: NormalizedRect
    ) -> CGRect? {
        guard let topLeftRect = screenshotPixelRect(
            from: rect,
            pixelSize: pixelSize,
            displayBounds: displayBounds
        ) else { return nil }
        return CGRect(
            x: topLeftRect.minX,
            y: pixelSize.height - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
    }
}
