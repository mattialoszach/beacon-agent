import AppKit
import SwiftUI

struct OverlayCanvasView: View {
    let presentation: OverlayController.Presentation
    let screenFrame: CGRect
    let mapper: CoordinateSpaceMapper
    /// Held without `@ObservedObject` on purpose: the cursor publishes at pointer rate and
    /// only the fade depends on it. Observing it here would re-evaluate the full-screen
    /// Canvas on every mouse move.
    let cursorPositionMonitor: CursorPositionMonitor
    var cursorMovementBaseline: UInt64 = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if OverlayDimmingPolicy.dimsBackground(
                    for: presentation.style,
                    targetRect: targetRect
                ), let targetRect {
                    Canvas { context, size in
                        var path = Path(CGRect(origin: .zero, size: size))
                        path.addRoundedRect(
                            in: targetRect.insetBy(dx: -8, dy: -8),
                            cornerSize: CGSize(width: 10, height: 10)
                        )
                        context.fill(
                            path,
                            with: .color(.black.opacity(OverlayDimmingPolicy.opacity)),
                            style: FillStyle(eoFill: true)
                        )
                    }
                    .allowsHitTesting(false)
                }

                CursorProximityFade(
                    cursorPositionMonitor: cursorPositionMonitor,
                    movementBaseline: cursorMovementBaseline,
                    screenFrame: screenFrame,
                    fadeRegions: fadeRegions(in: proxy.size)
                ) {
                    OverlayContentView(
                        presentation: presentation,
                        screenFrame: screenFrame,
                        mapper: mapper,
                        availableSize: proxy.size
                    )
                    .equatable()
                }
            }
        }
        .ignoresSafeArea()
    }

    var targetRect: CGRect? {
        OverlayGeometry.localRect(
            for: presentation.target?.bounds,
            screenFrame: screenFrame,
            mapper: mapper
        )
    }

    /// Regions whose contents the pointer may cover, in screen-local SwiftUI coordinates.
    func fadeRegions(in availableSize: CGSize) -> [CGRect] {
        guard let targetRect else { return [] }
        var regions = [targetRect.insetBy(dx: -18, dy: -18)]
        let callout = InstructionCalloutGeometry.layout(
            text: presentation.instruction,
            target: targetRect,
            availableSize: availableSize
        )
        regions.append(callout.frame.insetBy(dx: -8, dy: -8))
        if let arrow = GuidanceArrowGeometry.layout(
            target: targetRect,
            availableSize: availableSize,
            preferredSide: callout.preferredArrowSide(relativeTo: targetRect),
            avoiding: callout.frame
        ) {
            regions.append(arrow.hoverBounds)
        }
        return regions
    }

    func shouldFadeForCursor(in availableSize: CGSize) -> Bool {
        OverlayGeometry.fades(
            monitor: cursorPositionMonitor,
            movementBaseline: cursorMovementBaseline,
            screenFrame: screenFrame,
            fadeRegions: fadeRegions(in: availableSize)
        )
    }
}

enum OverlayGeometry {
    static func localRect(
        for bounds: NormalizedRect?,
        screenFrame: CGRect,
        mapper: CoordinateSpaceMapper
    ) -> CGRect? {
        guard let bounds, let global = mapper.appKitRect(from: bounds) else { return nil }
        let local = CoordinateSpaceMapper.localSwiftUIRect(fromGlobalAppKit: global, in: screenFrame)
        guard local.intersects(CGRect(origin: .zero, size: screenFrame.size)) else { return nil }
        return local
    }

    /// The single definition of the proximity-fade rule, shared by the live view and the
    /// value `OverlayCanvasView` exposes for tests, so the two cannot drift apart.
    @MainActor
    static func fades(
        monitor: CursorPositionMonitor,
        movementBaseline: UInt64,
        screenFrame: CGRect,
        fadeRegions: [CGRect]
    ) -> Bool {
        guard monitor.movementCount > movementBaseline else { return false }
        let cursor = CoordinateSpaceMapper.localSwiftUIPoint(
            fromGlobalAppKit: monitor.location,
            in: screenFrame
        )
        return fadeRegions.contains { $0.contains(cursor) }
    }
}

enum OverlayDimmingPolicy {
    static let opacity = 0.52

    /// Highlight shape is a presentation detail; it must never make otherwise identical
    /// grounded instructions switch between dimmed and undimmed backgrounds.
    static func dimsBackground(for _: OverlayStyle, targetRect: CGRect?) -> Bool {
        return targetRect != nil
    }
}

/// Applies the proximity fade without rebuilding the guidance content. Only this view
/// observes the cursor, so pointer movement never re-rasterizes the overlay canvas.
private struct CursorProximityFade<Content: View>: View {
    @ObservedObject var cursorPositionMonitor: CursorPositionMonitor
    let movementBaseline: UInt64
    let screenFrame: CGRect
    let fadeRegions: [CGRect]
    let content: Content

    init(
        cursorPositionMonitor: CursorPositionMonitor,
        movementBaseline: UInt64,
        screenFrame: CGRect,
        fadeRegions: [CGRect],
        @ViewBuilder content: () -> Content
    ) {
        self.cursorPositionMonitor = cursorPositionMonitor
        self.movementBaseline = movementBaseline
        self.screenFrame = screenFrame
        self.fadeRegions = fadeRegions
        self.content = content()
    }

    private var fades: Bool {
        OverlayGeometry.fades(
            monitor: cursorPositionMonitor,
            movementBaseline: movementBaseline,
            screenFrame: screenFrame,
            fadeRegions: fadeRegions
        )
    }

    var body: some View {
        content
            .opacity(fades ? 0.16 : 1)
            .animation(.easeOut(duration: 0.12), value: fades)
    }
}

private struct OverlayContentView: View, Equatable {
    let presentation: OverlayController.Presentation
    let screenFrame: CGRect
    let mapper: CoordinateSpaceMapper
    let availableSize: CGSize

    private var targetRect: CGRect? {
        OverlayGeometry.localRect(
            for: presentation.target?.bounds,
            screenFrame: screenFrame,
            mapper: mapper
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let targetRect {
                let callout = InstructionCalloutGeometry.layout(
                    text: presentation.instruction,
                    target: targetRect,
                    availableSize: availableSize
                )
                TargetHighlight(style: presentation.style)
                    .frame(width: max(12, targetRect.width), height: max(12, targetRect.height))
                    .position(x: targetRect.midX, y: targetRect.midY)

                GuidanceArrow(
                    target: targetRect,
                    availableSize: availableSize,
                    preferredSide: callout.preferredArrowSide(relativeTo: targetRect),
                    avoiding: callout.frame
                )

                InstructionCallout(
                    text: presentation.instruction,
                    target: targetRect,
                    availableSize: availableSize
                )
            }

            ForEach(presentation.debugElements) { element in
                if let rect = OverlayGeometry.localRect(
                    for: element.bounds,
                    screenFrame: screenFrame,
                    mapper: mapper
                ) {
                    DebugElementView(element: element)
                        .frame(width: max(18, rect.width), height: max(18, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}

private struct GuidanceArrow: View {
    @Environment(\.colorScheme) private var colorScheme

    let target: CGRect
    let availableSize: CGSize
    let preferredSide: GuidanceArrowGeometry.Side
    let avoiding: CGRect

    var body: some View {
        Canvas { context, _ in
            guard let geometry = GuidanceArrowGeometry.layout(
                target: target,
                availableSize: availableSize,
                preferredSide: preferredSide,
                avoiding: avoiding
            ) else {
                return
            }

            var shaft = Path()
            shaft.move(to: geometry.start)
            shaft.addQuadCurve(to: geometry.end, control: geometry.control)
            context.stroke(
                shaft,
                with: .color(colorScheme == .dark ? .white.opacity(0.24) : .black.opacity(0.22)),
                style: StrokeStyle(lineWidth: 9, lineCap: .round)
            )
            context.stroke(
                shaft,
                with: .color(colorScheme == .dark ? BeaconPalette.plum : BeaconPalette.blueViolet),
                style: StrokeStyle(lineWidth: 5, lineCap: .round)
            )

            let angle = atan2(
                geometry.end.y - geometry.control.y,
                geometry.end.x - geometry.control.x
            )
            let wing: CGFloat = 17
            var head = Path()
            head.move(to: geometry.end)
            head.addLine(to: CGPoint(
                x: geometry.end.x - wing * cos(angle - .pi / 6),
                y: geometry.end.y - wing * sin(angle - .pi / 6)
            ))
            head.move(to: geometry.end)
            head.addLine(to: CGPoint(
                x: geometry.end.x - wing * cos(angle + .pi / 6),
                y: geometry.end.y - wing * sin(angle + .pi / 6)
            ))
            context.stroke(
                head,
                with: .color(colorScheme == .dark ? .white.opacity(0.24) : .black.opacity(0.22)),
                style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                head,
                with: .color(colorScheme == .dark ? BeaconPalette.plum : BeaconPalette.blueViolet),
                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
            )
        }
        .allowsHitTesting(false)
    }
}

struct GuidanceArrowGeometry: Equatable {
    enum Side: Equatable {
        case top
        case right
        case bottom
        case left
    }

    let side: Side
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint

    var hoverBounds: CGRect {
        let minX = min(start.x, control.x, end.x)
        let maxX = max(start.x, control.x, end.x)
        let minY = min(start.y, control.y, end.y)
        let maxY = max(start.y, control.y, end.y)
        return CGRect(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        )
        .insetBy(dx: -18, dy: -18)
    }

    static func layout(
        target: CGRect,
        availableSize: CGSize,
        margin: CGFloat = 22,
        targetGap: CGFloat = 9,
        preferredLength: CGFloat = 78,
        preferredSide: Side? = nil,
        avoiding obstacle: CGRect? = nil
    ) -> GuidanceArrowGeometry? {
        guard availableSize.width.isFinite,
              availableSize.height.isFinite,
              target.origin.x.isFinite,
              target.origin.y.isFinite,
              target.width.isFinite,
              target.height.isFinite,
              availableSize.width > margin * 2,
              availableSize.height > margin * 2 else { return nil }

        let canvas = CGRect(origin: .zero, size: availableSize)
        let visibleTarget = target.standardized.intersection(canvas)
        guard !visibleTarget.isNull, !visibleTarget.isEmpty else { return nil }

        let clearances: [(Side, CGFloat)] = [
            (.top, visibleTarget.minY - margin),
            (.right, availableSize.width - margin - visibleTarget.maxX),
            (.bottom, availableSize.height - margin - visibleTarget.maxY),
            (.left, visibleTarget.minX - margin)
        ]
        let eligiblePlacements = clearances.filter { $0.1 >= targetGap + 20 }
        var placements: [(Side, CGFloat)] = []
        if let preferredSide,
           let preferred = eligiblePlacements.first(where: { $0.0 == preferredSide }) {
            placements.append(preferred)
        }
        placements.append(contentsOf: eligiblePlacements
            .filter { $0.0 != preferredSide }
            .sorted { $0.1 > $1.1 })

        return placements.lazy.compactMap { placement in
            candidate(
                placement: placement,
                visibleTarget: visibleTarget,
                availableSize: availableSize,
                targetGap: targetGap,
                preferredLength: preferredLength
            )
        }
        .first { geometry in
            guard let obstacle else { return true }
            return !geometry.hoverBounds.intersects(obstacle)
        }
    }

    private static func candidate(
        placement: (Side, CGFloat),
        visibleTarget: CGRect,
        availableSize: CGSize,
        targetGap: CGFloat,
        preferredLength: CGFloat
    ) -> GuidanceArrowGeometry {
        let shaftLength = min(preferredLength, placement.1 - targetGap)
        let end: CGPoint
        let start: CGPoint

        switch placement.0 {
        case .top:
            end = CGPoint(x: visibleTarget.midX, y: visibleTarget.minY - targetGap)
            start = CGPoint(x: end.x, y: end.y - shaftLength)
        case .right:
            end = CGPoint(x: visibleTarget.maxX + targetGap, y: visibleTarget.midY)
            start = CGPoint(x: end.x + shaftLength, y: end.y)
        case .bottom:
            end = CGPoint(x: visibleTarget.midX, y: visibleTarget.maxY + targetGap)
            start = CGPoint(x: end.x, y: end.y + shaftLength)
        case .left:
            end = CGPoint(x: visibleTarget.minX - targetGap, y: visibleTarget.midY)
            start = CGPoint(x: end.x - shaftLength, y: end.y)
        }

        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let bend: CGFloat = 7
        let control: CGPoint
        switch placement.0 {
        case .top, .bottom:
            control = CGPoint(
                x: midpoint.x + (visibleTarget.midX < availableSize.width / 2 ? bend : -bend),
                y: midpoint.y
            )
        case .right, .left:
            control = CGPoint(
                x: midpoint.x,
                y: midpoint.y + (visibleTarget.midY < availableSize.height / 2 ? bend : -bend)
            )
        }

        return GuidanceArrowGeometry(
            side: placement.0,
            start: start,
            control: control,
            end: end
        )
    }
}

struct InstructionCalloutGeometry: Equatable {
    let width: CGFloat
    let height: CGFloat
    let position: CGPoint

    var frame: CGRect {
        CGRect(
            x: position.x - width / 2,
            y: position.y - height / 2,
            width: width,
            height: height
        )
    }

    func preferredArrowSide(relativeTo target: CGRect) -> GuidanceArrowGeometry.Side {
        position.y < target.midY ? .top : .bottom
    }

    static func layout(
        text: String,
        target: CGRect,
        availableSize: CGSize
    ) -> InstructionCalloutGeometry {
        let width = max(180, min(420, availableSize.width - 24))
        let charactersPerLine = max(18, Int((width - 58) / 7))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { count, line in
            count + max(1, Int(ceil(Double(line.count) / Double(charactersPerLine))))
        }
        let height = 38 + CGFloat(lines * 18)
        let x = min(
            max(width / 2 + 12, target.midX),
            availableSize.width - width / 2 - 12
        )
        let spacing: CGFloat = 16
        let below = target.maxY + spacing + height / 2
        let above = target.minY - spacing - height / 2
        let preferredY = below + height / 2 + 12 <= availableSize.height ? below : above
        let y = min(
            max(height / 2 + 12, preferredY),
            availableSize.height - height / 2 - 12
        )
        return InstructionCalloutGeometry(
            width: width,
            height: height,
            position: CGPoint(x: x, y: y)
        )
    }
}

private struct TargetHighlight: View {
    let style: OverlayStyle

    var body: some View {
        RoundedRectangle(cornerRadius: style == .circle ? 999 : 8)
            .stroke(BeaconPalette.blueViolet, lineWidth: 4)
            .background(
                RoundedRectangle(cornerRadius: style == .circle ? 999 : 8)
                    .fill(BeaconPalette.plum.opacity(0.18))
            )
            .shadow(color: .black.opacity(0.35), radius: 8)
            .animation(.easeOut(duration: 0.18), value: style)
    }
}

private struct InstructionCallout: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let target: CGRect
    let availableSize: CGSize

    private var geometry: InstructionCalloutGeometry {
        InstructionCalloutGeometry.layout(
            text: text,
            target: target,
            availableSize: availableSize
        )
    }

    private var instructionColor: Color {
        colorScheme == .dark ? BeaconPalette.plum : BeaconPalette.blueViolet
    }

    private var directionIcon: String {
        geometry.position.y < target.midY ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: directionIcon)
                .foregroundStyle(instructionColor)
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(instructionColor)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(width: geometry.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .background(
            BeaconPalette.lavender.opacity(colorScheme == .dark ? 0.05 : 0.12),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(BeaconPalette.blueViolet.opacity(0.28))
        )
        .shadow(radius: 12)
        .position(geometry.position)
    }
}

private struct DebugElementView: View {
    let element: UIElementDescriptor

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(element.focused ? .yellow : .cyan, lineWidth: element.focused ? 3 : 1)
            Text("[\(element.id.replacingOccurrences(of: "e_", with: ""))] \(element.bestLabel)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(.black.opacity(0.85))
                .fixedSize()
        }
    }
}
