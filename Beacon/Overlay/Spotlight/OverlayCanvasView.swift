import AppKit
import SwiftUI

struct OverlayCanvasView: View {
    let presentation: OverlayController.Presentation
    let screenFrame: CGRect
    let mapper: CoordinateSpaceMapper

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if presentation.style == .spotlight, let targetRect {
                    Canvas { context, size in
                        var path = Path(CGRect(origin: .zero, size: size))
                        path.addRoundedRect(in: targetRect.insetBy(dx: -8, dy: -8), cornerSize: CGSize(width: 10, height: 10))
                        context.fill(path, with: .color(.black.opacity(0.52)), style: FillStyle(eoFill: true))
                    }
                }

                if let targetRect {
                    TargetHighlight(style: presentation.style)
                        .frame(width: max(12, targetRect.width), height: max(12, targetRect.height))
                        .position(x: targetRect.midX, y: targetRect.midY)

                    InstructionCallout(text: presentation.instruction, target: targetRect, availableSize: proxy.size)

                    if presentation.style == .arrow {
                        GuidanceArrow(target: targetRect, availableSize: proxy.size)
                    }
                }

                ForEach(presentation.debugElements) { element in
                    if let rect = localRect(for: element.bounds), rect.intersects(CGRect(origin: .zero, size: proxy.size)) {
                        DebugElementView(element: element)
                            .frame(width: max(18, rect.width), height: max(18, rect.height))
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private var targetRect: CGRect? {
        localRect(for: presentation.target?.bounds)
    }

    private func localRect(for bounds: NormalizedRect?) -> CGRect? {
        guard let bounds, let global = mapper.appKitRect(from: bounds) else { return nil }
        return CGRect(
            x: global.minX - screenFrame.minX,
            y: screenFrame.maxY - global.maxY,
            width: global.width,
            height: global.height
        )
    }
}

private struct GuidanceArrow: View {
    let target: CGRect
    let availableSize: CGSize

    var body: some View {
        Canvas { context, _ in
            let rightSide = target.midX < availableSize.width / 2
            let start = CGPoint(
                x: rightSide ? min(availableSize.width - 24, target.maxX + 92) : max(24, target.minX - 92),
                y: max(24, target.minY - 62)
            )
            let end = CGPoint(x: target.midX, y: target.midY)
            var shaft = Path()
            shaft.move(to: start)
            shaft.addLine(to: end)
            context.stroke(shaft, with: .color(.accentColor), style: StrokeStyle(lineWidth: 5, lineCap: .round))

            let angle = atan2(end.y - start.y, end.x - start.x)
            let wing: CGFloat = 17
            var head = Path()
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - wing * cos(angle - .pi / 6), y: end.y - wing * sin(angle - .pi / 6)))
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - wing * cos(angle + .pi / 6), y: end.y - wing * sin(angle + .pi / 6)))
            context.stroke(head, with: .color(.accentColor), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

private struct TargetHighlight: View {
    let style: OverlayStyle

    var body: some View {
        RoundedRectangle(cornerRadius: style == .circle ? 999 : 8)
            .stroke(Color.accentColor, lineWidth: 4)
            .background(
                RoundedRectangle(cornerRadius: style == .circle ? 999 : 8)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .shadow(color: .black.opacity(0.35), radius: 8)
            .animation(.easeOut(duration: 0.18), value: style)
    }
}

private struct InstructionCallout: View {
    let text: String
    let target: CGRect
    let availableSize: CGSize

    private var calloutWidth: CGFloat {
        max(180, min(420, availableSize.width - 24))
    }

    private var estimatedHeight: CGFloat {
        let charactersPerLine = max(18, Int((calloutWidth - 58) / 7))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { count, line in
            count + max(1, Int(ceil(Double(line.count) / Double(charactersPerLine))))
        }
        return 38 + CGFloat(lines * 18)
    }

    private var position: CGPoint {
        let x = min(
            max(calloutWidth / 2 + 12, target.midX),
            availableSize.width - calloutWidth / 2 - 12
        )
        let spacing: CGFloat = 16
        let below = target.maxY + spacing + estimatedHeight / 2
        let above = target.minY - spacing - estimatedHeight / 2
        let preferredY = below + estimatedHeight / 2 + 12 <= availableSize.height ? below : above
        let y = min(
            max(estimatedHeight / 2 + 12, preferredY),
            availableSize.height - estimatedHeight / 2 - 12
        )
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.left")
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(width: calloutWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.2)))
        .shadow(radius: 12)
        .position(position)
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
