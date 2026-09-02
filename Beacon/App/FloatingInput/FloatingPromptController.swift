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
}

private final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct FloatingPromptLayout {
    static let panelSize = CGSize(width: 440, height: 176)
    static let promptSize = CGSize(width: 408, height: 142)
    static let thinkingSize = CGSize(width: 64, height: 64)
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
            promptContents
            ThinkingCore(message: presentation.message)
                .opacity(isThinking ? 1 : 0)
                .scaleEffect(isThinking ? 1 : 0.62)
                .blur(radius: isThinking ? 0 : 5)
                .accessibilityHidden(!isThinking)
                .animation(
                    reduceMotion
                        ? nil
                        : .spring(response: 0.48, dampingFraction: 0.78)
                            .delay(isThinking ? 0.12 : 0),
                    value: isThinking
                )
        }
        .frame(
            width: isThinking ? FloatingPromptLayout.thinkingSize.width : FloatingPromptLayout.promptSize.width,
            height: isThinking ? FloatingPromptLayout.thinkingSize.height : FloatingPromptLayout.promptSize.height
        )
        .clipShape(RoundedRectangle(cornerRadius: isThinking ? 32 : 18, style: .continuous))
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
        }
        .shadow(
            color: .black.opacity(isThinking ? 0.2 : 0.24),
            radius: isThinking ? 18 : 28,
            y: isThinking ? 9 : 14
        )
        .offset(y: isThinking ? FloatingPromptLayout.thinkingOffsetY : FloatingPromptLayout.promptOffsetY)
        .frame(width: FloatingPromptLayout.panelSize.width, height: FloatingPromptLayout.panelSize.height)
        .animation(
            reduceMotion ? nil : .spring(response: 0.62, dampingFraction: 0.86),
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

private struct ThinkingCore: View {
    let message: String

    var body: some View {
        MorphingThinkingMark()
            .frame(width: 46, height: 46)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Beacon is thinking. \(message)")
            .accessibilityHint("Press Escape to cancel")
    }
}

private struct MorphingThinkingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas(rendersAsynchronously: true) { context, size in
                let path = blobPath(in: size, time: time)
                let gradientStart = CGPoint(
                    x: size.width * (0.22 + 0.05 * cos(time * 0.7)),
                    y: size.height * 0.18
                )
                let gradientEnd = CGPoint(
                    x: size.width * 0.82,
                    y: size.height * (0.78 + 0.04 * sin(time * 0.6))
                )

                var glow = context
                glow.addFilter(.blur(radius: 6))
                glow.opacity = 0.52
                glow.fill(
                    path,
                    with: .color(BeaconPalette.mediumPurple.opacity(0.7))
                )

                context.fill(
                    path,
                    with: .linearGradient(
                        BeaconPalette.thinkingGradient,
                        startPoint: gradientStart,
                        endPoint: gradientEnd
                    )
                )
                context.fill(
                    path,
                    with: .radialGradient(
                        Gradient(colors: [.white.opacity(0.72), .clear]),
                        center: CGPoint(x: size.width * 0.36, y: size.height * 0.3),
                        startRadius: 0,
                        endRadius: size.width * 0.34
                    )
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func blobPath(in size: CGSize, time: TimeInterval) -> Path {
        let center = CGPoint(
            x: size.width / 2 + cos(time * 0.74) * 0.7,
            y: size.height / 2 + sin(time * 0.62) * 0.6
        )
        let baseRadius = min(size.width, size.height) * 0.27
        let pointCount = 12
        let points = (0..<pointCount).map { index in
            let angle = Double(index) / Double(pointCount) * .pi * 2
            let deformation = sin(angle * 3 + time * 1.15) * 0.065
                + cos(angle * 2 - time * 0.82) * 0.045
            let breath = reduceMotion ? 0 : sin(time * 1.04) * 0.025
            let radius = baseRadius * (1 + deformation + breath)
            return CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
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
