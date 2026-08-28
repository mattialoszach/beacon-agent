import AppKit
import CoreGraphics

struct DisplayGeometryProvider {
    func currentMapper() -> CoordinateSpaceMapper {
        let displayBounds = activeDisplayBounds()
        let virtual = displayBounds.dropFirst().reduce(displayBounds.first ?? .zero) { $0.union($1) }
        return CoordinateSpaceMapper(
            virtualDesktopBounds: virtual,
            appKitMainScreenMaxY: NSScreen.screens.first?.frame.maxY ?? virtual.height
        )
    }

    func descriptors(using mapper: CoordinateSpaceMapper) -> [DisplayDescriptor] {
        activeDisplayIDs().compactMap { id in
            guard let bounds = mapper.normalizeAXRect(CGDisplayBounds(id)) else { return nil }
            let pixelsWide = CGFloat(CGDisplayPixelsWide(id))
            let logicalWidth = max(1, CGDisplayBounds(id).width)
            return DisplayDescriptor(id: id, bounds: bounds, scaleFactor: pixelsWide / logicalWidth)
        }
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
