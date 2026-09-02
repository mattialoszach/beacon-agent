import AppKit
import SwiftUI

@MainActor
final class FloatingPromptController {
    private var panel: PromptPanel?
    private var presentation: FloatingPromptPresentation?

    func show(
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        close()
        let panel = makePanel()
        let presentation = FloatingPromptPresentation(
            onSubmit: { [weak self] question in
                self?.showThinking(
                    message: "Reading the current interface…",
                    onCancel: onCancel
                )
                onSubmit(question)
            },
            onCancel: { [weak self] in
                self?.close()
                onCancel()
            }
        )
        panel.contentView = NSHostingView(rootView: FloatingPromptView(
            presentation: presentation
        ))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.presentation = presentation
        focusPrompt(in: panel)
    }

    func showThinking(message: String, onCancel: @escaping () -> Void) {
        if let presentation {
            panel?.ignoresMouseEvents = true
            presentation.showThinking(message: message)
            return
        }

        let panel = makePanel()
        let presentation = FloatingPromptPresentation(
            mode: .thinking,
            message: message,
            onSubmit: { _ in },
            onCancel: { [weak self] in
                self?.close()
                onCancel()
            }
        )
        panel.contentView = NSHostingView(rootView: FloatingPromptView(
            presentation: presentation
        ))
        panel.ignoresMouseEvents = true
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.presentation = presentation
    }

    func updateThinking(message: String) {
        presentation?.updateThinking(message: message)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        presentation = nil
    }

    private func makePanel() -> PromptPanel {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let panelSize = FloatingPromptLayout.panelSize
        let visible = screen?.visibleFrame ?? CGRect(origin: mouse, size: panelSize)
        let origin = CGPoint(
            x: min(
                max(mouse.x - panelSize.width / 2, visible.minX + 12),
                visible.maxX - panelSize.width - 12
            ),
            y: min(
                max(mouse.y - panelSize.height - 18, visible.minY + 12),
                visible.maxY - panelSize.height - 12
            )
        )
        let panel = PromptPanel(
            contentRect: CGRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func focusPrompt(in panel: PromptPanel, attempt: Int = 0) {
        let delay = attempt == 0 ? DispatchTimeInterval.milliseconds(0) : .milliseconds(30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak panel] in
            guard let self,
                  let panel,
                  self.panel === panel,
                  self.presentation?.mode == .prompt else { return }

            panel.contentView?.layoutSubtreeIfNeeded()
            panel.makeKey()
            if let textField = panel.contentView.flatMap(PromptFocusResolver.editableTextField),
               panel.makeFirstResponder(textField) {
                return
            }

            guard attempt < 3 else { return }
            self.focusPrompt(in: panel, attempt: attempt + 1)
        }
    }
}

private final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum PromptFocusResolver {
    static func editableTextField(in root: NSView) -> NSTextField? {
        if let textField = root as? NSTextField,
           textField.isEditable,
           textField.isEnabled {
            return textField
        }

        for subview in root.subviews {
            if let textField = editableTextField(in: subview) {
                return textField
            }
        }
        return nil
    }
}

struct FloatingPromptLayout {
    static let panelSize = CGSize(width: 440, height: 176)
    static let promptSize = CGSize(width: 408, height: 142)
    static let thinkingSize = CGSize(width: 72, height: 72)
    static let promptOffsetY: CGFloat = -9
    static let thinkingOffsetY: CGFloat = 42

    static func surfaceFrame(isThinking: Bool) -> CGRect {
        let size = isThinking ? thinkingSize : promptSize
        let offsetY = isThinking ? thinkingOffsetY : promptOffsetY
        return CGRect(
            x: (panelSize.width - size.width) / 2,
            y: (panelSize.height - size.height) / 2 + offsetY,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
private final class FloatingPromptPresentation: ObservableObject {
    enum Mode: Equatable {
        case prompt
        case thinking
    }

    @Published private(set) var mode: Mode
    @Published private(set) var message: String

    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    init(
        mode: Mode = .prompt,
        message: String = "",
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.message = message
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    func showThinking(message: String) {
        self.message = message
        mode = .thinking
    }

    func updateThinking(message: String) {
        guard mode == .thinking else { return }
        self.message = message
    }
}

private struct FloatingPromptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var presentation: FloatingPromptPresentation

    @State private var question = ""
    @FocusState private var focused: Bool

    private var isThinking: Bool { presentation.mode == .thinking }

    var body: some View {
        ZStack {
            surface
                .opacity(isThinking ? 0 : 1)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: 0.34).delay(isThinking ? 0.06 : 0),
                    value: isThinking
                )
            promptContents
            DreamyThinkingOrb(message: presentation.message)
                .opacity(isThinking ? 1 : 0)
                .scaleEffect(isThinking ? 1 : 0.72)
                .blur(radius: isThinking ? 0 : 8)
                .accessibilityHidden(!isThinking)
                .animation(
                    reduceMotion
                        ? nil
                        : .spring(response: 0.6, dampingFraction: 0.86, blendDuration: 0.1)
                            .delay(isThinking ? 0.08 : 0),
                    value: isThinking
                )
        }
        .frame(
            width: isThinking ? FloatingPromptLayout.thinkingSize.width : FloatingPromptLayout.promptSize.width,
            height: isThinking ? FloatingPromptLayout.thinkingSize.height : FloatingPromptLayout.promptSize.height
        )
        .clipShape(RoundedRectangle(cornerRadius: isThinking ? 0 : 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isThinking ? 32 : 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.46), .white.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .opacity(isThinking ? 0 : 1)
        }
        .shadow(
            color: .black.opacity(isThinking ? 0.2 : 0.24),
            radius: isThinking ? 18 : 28,
            y: isThinking ? 9 : 14
        )
        .offset(y: isThinking ? FloatingPromptLayout.thinkingOffsetY : FloatingPromptLayout.promptOffsetY)
        .frame(width: FloatingPromptLayout.panelSize.width, height: FloatingPromptLayout.panelSize.height)
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.74, dampingFraction: 0.9, blendDuration: 0.12),
            value: isThinking
        )
        .onAppear { focused = !isThinking }
        .onChange(of: presentation.mode) { _, mode in
            focused = mode == .prompt
        }
        .onExitCommand(perform: presentation.onCancel)
        .tint(BeaconPalette.blueViolet)
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: isThinking ? 32 : 18, style: .continuous)
            .fill(.ultraThickMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: isThinking ? 32 : 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                BeaconPalette.lavender.opacity(isThinking ? 0.22 : 0.12),
                                BeaconPalette.thistle.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
    }

    private var promptContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Ask Beacon", systemImage: "scope")
                    .font(.headline)
                Spacer()
                Text("Ask a question or describe a task")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TextField("What do you want to know or do?", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(BeaconPalette.accentGradient, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.42 : 1)
            }
            .padding(12)
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            Text("Return to send  ·  Esc to dismiss  ·  Beacon never clicks for you")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: FloatingPromptLayout.promptSize.width, height: FloatingPromptLayout.promptSize.height)
        .opacity(isThinking ? 0 : 1)
        .scaleEffect(isThinking ? 0.94 : 1)
        .blur(radius: isThinking ? 3 : 0)
        .allowsHitTesting(!isThinking)
        .accessibilityHidden(isThinking)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isThinking)
    }

    private func submit() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presentation.onSubmit(trimmed)
    }
}

private struct DreamyThinkingOrb: View {
    let message: String

    var body: some View {
        TranslucentThinkingForm()
            .frame(
                width: FloatingPromptLayout.thinkingSize.width,
                height: FloatingPromptLayout.thinkingSize.height
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Beacon is thinking. \(message)")
            .accessibilityHint("Press Escape to cancel")
    }
}

private struct TranslucentThinkingForm: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                LiquidGlassBackdrop(time: time)

                Canvas(rendersAsynchronously: true) { context, size in
                    let shell = ThinkingGlassShape(time: time).path(
                        in: CGRect(origin: .zero, size: size)
                    )
                    let layers = manifoldLayers(in: size, time: time)

                    context.drawLayer { field in
                        field.clip(to: shell)
                        field.fill(
                            shell,
                            with: .linearGradient(
                                Gradient(stops: [
                                    .init(color: BeaconPalette.blueViolet.opacity(0.34), location: 0),
                                    .init(color: BeaconPalette.plum.opacity(0.28), location: 0.44),
                                    .init(color: BeaconPalette.mediumPurple.opacity(0.38), location: 1)
                                ]),
                                startPoint: CGPoint(
                                    x: size.width * (0.12 + cos(time * 1.34) * 0.12),
                                    y: size.height * (0.08 + sin(time * 1.18) * 0.1)
                                ),
                                endPoint: CGPoint(
                                    x: size.width * (0.9 + sin(time * 1.26) * 0.08),
                                    y: size.height * (0.92 + cos(time * 1.42) * 0.08)
                                )
                            )
                        )
                    }

                    context.drawLayer { glow in
                        glow.clip(to: shell)
                        glow.addFilter(.blur(radius: 5.5))
                        glow.blendMode = .plusLighter

                        for layer in layers {
                            glow.fill(
                                layer.path,
                                with: .color(layer.color.opacity(layer.opacity * 0.62))
                            )
                        }
                    }

                    context.drawLayer { membranes in
                        membranes.clip(to: shell)
                        membranes.addFilter(.blur(radius: 0.8))
                        membranes.blendMode = .screen

                        for layer in layers {
                            membranes.fill(
                                layer.path,
                                with: .radialGradient(
                                    Gradient(stops: [
                                        .init(color: .white.opacity(layer.opacity * 0.34), location: 0),
                                        .init(
                                            color: layer.highlight.opacity(layer.opacity),
                                            location: 0.2
                                        ),
                                        .init(
                                            color: layer.color.opacity(layer.opacity * 0.92),
                                            location: 0.55
                                        ),
                                        .init(
                                            color: layer.color.opacity(layer.opacity * 0.26),
                                            location: 0.82
                                        ),
                                        .init(
                                            color: .clear,
                                            location: 1
                                        )
                                    ]),
                                    center: layer.focus,
                                    startRadius: 0,
                                    endRadius: layer.gradientRadius
                                )
                            )
                        }
                    }

                }

                LiquidGlassSurface(time: time)
            }
        }
        .accessibilityHidden(true)
    }

    private func manifoldLayers(in size: CGSize, time: TimeInterval) -> [ManifoldLayer] {
        let descriptors = [
            ManifoldDescriptor(
                color: BeaconPalette.blueViolet,
                highlight: BeaconPalette.plum,
                opacity: 0.82,
                radius: 0.38,
                orbit: 0.25,
                orbitSpeed: 1.72,
                morphSpeed: 2.34,
                phase: 0.2
            ),
            ManifoldDescriptor(
                color: BeaconPalette.plum,
                highlight: BeaconPalette.lavender,
                opacity: 0.78,
                radius: 0.36,
                orbit: 0.27,
                orbitSpeed: -1.94,
                morphSpeed: 2.68,
                phase: 1.34
            ),
            ManifoldDescriptor(
                color: BeaconPalette.mediumPurple,
                highlight: BeaconPalette.thistle,
                opacity: 0.86,
                radius: 0.42,
                orbit: 0.22,
                orbitSpeed: 2.12,
                morphSpeed: 2.86,
                phase: 2.42
            ),
            ManifoldDescriptor(
                color: BeaconPalette.thistle,
                highlight: BeaconPalette.plum,
                opacity: 0.72,
                radius: 0.34,
                orbit: 0.31,
                orbitSpeed: -2.28,
                morphSpeed: 3.08,
                phase: 3.56
            ),
            ManifoldDescriptor(
                color: BeaconPalette.blueViolet,
                highlight: BeaconPalette.lavender,
                opacity: 0.76,
                radius: 0.3,
                orbit: 0.33,
                orbitSpeed: 2.46,
                morphSpeed: 3.32,
                phase: 4.68
            ),
            ManifoldDescriptor(
                color: BeaconPalette.plum,
                highlight: BeaconPalette.mediumPurple,
                opacity: 0.8,
                radius: 0.33,
                orbit: 0.29,
                orbitSpeed: -2.62,
                morphSpeed: 3.54,
                phase: 5.74
            )
        ]

        let dimension = min(size.width, size.height)
        return descriptors.map { descriptor in
            let orbitAngle = time * descriptor.orbitSpeed + descriptor.phase
                + sin(time * 2.18 + descriptor.phase) * 0.28
            let orbit = dimension * descriptor.orbit
                * (0.78 + sin(time * 2.72 + descriptor.phase) * 0.18)
            let center = CGPoint(
                x: size.width / 2 + cos(orbitAngle) * orbit,
                y: size.height / 2 + sin(orbitAngle * 1.08 + descriptor.phase * 0.24) * orbit
            )
            let radius = dimension * descriptor.radius
                * (1 + sin(time * 3.26 + descriptor.phase) * 0.1)
            let focus = CGPoint(
                x: center.x + cos(time * 2.84 + descriptor.phase) * radius * 0.28,
                y: center.y + sin(time * 3.06 + descriptor.phase) * radius * 0.24
            )
            return ManifoldLayer(
                color: descriptor.color,
                highlight: descriptor.highlight,
                opacity: descriptor.opacity,
                path: ThinkingFormPath.make(
                    center: center,
                    radius: radius,
                    time: time * descriptor.morphSpeed,
                    phase: descriptor.phase,
                    deformation: 0.12,
                    pointCount: 28
                ),
                focus: focus,
                gradientRadius: radius * 1.24
            )
        }
    }

    private struct ManifoldDescriptor {
        let color: Color
        let highlight: Color
        let opacity: Double
        let radius: CGFloat
        let orbit: CGFloat
        let orbitSpeed: Double
        let morphSpeed: Double
        let phase: Double
    }

    private struct ManifoldLayer {
        let color: Color
        let highlight: Color
        let opacity: Double
        let path: Path
        let focus: CGPoint
        let gradientRadius: CGFloat
    }
}

private struct LiquidGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    let time: TimeInterval

    private var adaptiveTint: Color {
        colorScheme == .dark ? .black.opacity(0.2) : .white.opacity(0.2)
    }

    var body: some View {
        let rearShape = ThinkingGlassShape(
            time: time * 0.87 + 3.4,
            radiusScale: 1.07,
            deformation: 0.032,
            phase: 1.7
        )
        let frontShape = ThinkingGlassShape(time: time)

        ZStack {
            rearShape
                .fill(adaptiveTint)
                .blur(radius: 1.1)
                .shadow(
                    color: colorScheme == .dark ? .black.opacity(0.42) : .black.opacity(0.18),
                    radius: 15,
                    y: 7
                )

            frontShape
                .fill(.ultraThinMaterial)
                .opacity(colorScheme == .dark ? 0.66 : 0.56)
        }
            .accessibilityHidden(true)
    }
}

private struct LiquidGlassSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    let time: TimeInterval

    var body: some View {
        let shape = ThinkingGlassShape(time: time)

        shape
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: .white.opacity(0.42), location: 0),
                        .init(color: .white.opacity(0.12), location: 0.18),
                        .init(color: .clear, location: 0.54)
                    ],
                    center: UnitPoint(
                        x: 0.27 + cos(time * 1.86) * 0.05,
                        y: 0.2 + sin(time * 1.72) * 0.04
                    ),
                    startRadius: 0,
                    endRadius: 46
                )
            )
            .overlay {
                shape.stroke(
                    AngularGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.58 : 0.82),
                            BeaconPalette.lavender.opacity(0.48),
                            BeaconPalette.plum.opacity(0.56),
                            BeaconPalette.blueViolet.opacity(0.6),
                            .white.opacity(colorScheme == .dark ? 0.5 : 0.74)
                        ],
                        center: .center,
                        angle: .radians(time * 1.22)
                    ),
                    lineWidth: 0.9
                )
            }
            .overlay {
                shape
                    .inset(by: 2.2)
                    .stroke(.white.opacity(0.2), lineWidth: 0.55)
                    .blur(radius: 0.3)
            }
            .accessibilityHidden(true)
    }
}

private struct ThinkingGlassShape: InsettableShape {
    let time: TimeInterval
    var radiusScale: CGFloat = 1
    var deformation: Double = 0.04
    var phase: Double = 3.8
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> ThinkingGlassShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let dimension = min(rect.width, rect.height)
        let center = CGPoint(
            x: rect.midX + cos(time * 1.82 + phase) * dimension * 0.006,
            y: rect.midY + sin(time * 1.64 + phase * 0.72) * dimension * 0.006
        )
        let breath = 1
            + sin(time * 2.82 + phase) * 0.026
            + cos(time * 4.06 - phase) * 0.008
        return ThinkingFormPath.make(
            center: center,
            radius: max(0, dimension * 0.445 * radiusScale * breath - insetAmount),
            time: time * 1.54,
            phase: phase,
            deformation: deformation,
            pointCount: 30
        )
    }
}

private enum ThinkingFormPath {
    static func make(
        center: CGPoint,
        radius: CGFloat,
        time: TimeInterval,
        phase: Double,
        deformation: Double,
        pointCount: Int
    ) -> Path {
        let points = (0..<pointCount).map { index in
            let angle = Double(index) / Double(pointCount) * .pi * 2
            let offset = sin(angle * 3 + time * 1.18 + phase) * deformation
                + cos(angle * 5 - time * 0.94 - phase * 0.7) * deformation * 0.48
                + sin(angle * 2 + time * 0.76 + phase * 1.2) * deformation * 0.22
            let pointRadius = radius * (1 + offset)
            return CGPoint(
                x: center.x + cos(angle) * pointRadius,
                y: center.y + sin(angle) * pointRadius
            )
        }

        var path = Path()
        path.move(to: points[0])
        for index in 0..<pointCount {
            let previous = points[(index - 1 + pointCount) % pointCount]
            let current = points[index]
            let next = points[(index + 1) % pointCount]
            let following = points[(index + 2) % pointCount]
            path.addCurve(
                to: next,
                control1: CGPoint(
                    x: current.x + (next.x - previous.x) / 6,
                    y: current.y + (next.y - previous.y) / 6
                ),
                control2: CGPoint(
                    x: next.x - (following.x - current.x) / 6,
                    y: next.y - (following.y - current.y) / 6
                )
            )
        }
        path.closeSubpath()
        return path
    }
}
