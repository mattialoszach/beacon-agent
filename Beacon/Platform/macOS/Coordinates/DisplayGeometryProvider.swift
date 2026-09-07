import AppKit
import CoreGraphics

struct DisplayGeometryProvider {
    func currentMapper() -> CoordinateSpaceMapper {
        let displayBounds = activeDisplayBounds()
        let virtual = displayBounds.dropFirst().reduce(displayBounds.first ?? .zero) { $0.union($1) }
        return CoordinateSpaceMapper(
            virtualDesktopBounds: virtual,
            appKitMainScreenMaxY: CGDisplayBounds(CGMainDisplayID()).height
        )
    }

    func descriptors(using mapper: CoordinateSpaceMapper) -> [DisplayDescriptor] {
        activeDisplayIDs().compactMap { id in
            guard let bounds = mapper.normalizeAXRect(CGDisplayBounds(id)) else { return nil }
            return DisplayDescriptor(
                id: id, bounds: bounds, scaleFactor: Self.backingScaleFactor(of: id),
                logicalSize: CGDisplayBounds(id).size
            )
        }
    }

    /// `CGDisplayPixelsWide` reports the logical mode width, so it is 1.0 for every
    /// Retina display. Only the display mode exposes the backing pixel width, which a
    /// scale-only mode change alters while bounds and logical size stay identical.
    static func backingScaleFactor(of id: CGDirectDisplayID) -> Double {
        let logicalWidth = max(1, CGDisplayBounds(id).width)
        let pixelWidth = CGDisplayCopyDisplayMode(id).map { CGFloat($0.pixelWidth) }
            ?? CGFloat(CGDisplayPixelsWide(id))
        guard pixelWidth > 0 else { return 1 }
        return pixelWidth / logicalWidth
    }

    func display(containing point: CGPoint) -> CGDirectDisplayID? {
        activeDisplayIDs().first { CGDisplayBounds($0).contains(point) }
    }

    private func activeDisplayBounds() -> [CGRect] {
        activeDisplayIDs().map(CGDisplayBounds)
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
}
