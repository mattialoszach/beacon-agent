import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    struct Presentation: Equatable {
        let target: GroundedTarget?
        let instruction: String
        let style: OverlayStyle
        let debugElements: [UIElementDescriptor]
    }

    private var panels: [NSPanel] = []
    private let cursorPositionMonitor: CursorPositionMonitor
    private var escapeMonitor: Any?
    private var isMonitoringCursor = false
    private(set) var presentation: Presentation?
    var onDismiss: (() -> Void)?

    init() {
        cursorPositionMonitor = CursorPositionMonitor()
    }

    init(cursorPositionMonitor: CursorPositionMonitor) {
        self.cursorPositionMonitor = cursorPositionMonitor
    }

    func showInstruction(_ instruction: VisualInstruction) {
        show(Presentation(
            target: instruction.target,
            instruction: instruction.text,
            style: instruction.overlay,
            debugElements: []
        ))
    }

    func showDebugElements(_ elements: [UIElementDescriptor]) {
        show(Presentation(
            target: nil,
            instruction: "Accessibility map",
            style: .numberedBadge,
            debugElements: elements
        ))
    }

    func updateTarget(_ target: GroundedTarget) {
        guard let current = presentation else { return }
        update(Presentation(
            target: target,
            instruction: current.instruction,
            style: current.style,
            debugElements: current.debugElements
        ))
    }

    func updateDebugElements(_ elements: [UIElementDescriptor]) {
        guard let current = presentation else { return }
        update(Presentation(
            target: current.target,
            instruction: current.instruction,
            style: current.style,
            debugElements: elements
        ))
    }

    func dismiss() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        presentation = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        endCursorMonitoring()
    }

    private func show(_ presentation: Presentation) {
        self.presentation = presentation
        let mapper = DisplayGeometryProvider().currentMapper()

        if !panels.isEmpty {
            render(presentation, mapper: mapper)
            return
        }

        beginCursorMonitoring()

        for screen in NSScreen.screens {
            let panel = ClickThroughPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = makeContent(presentation, screenFrame: screen.frame, mapper: mapper)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                self?.dismiss()
                self?.onDismiss?()
            }
        }
    }

    private func update(_ presentation: Presentation) {
        self.presentation = presentation
        render(presentation, mapper: DisplayGeometryProvider().currentMapper())
    }

    private func render(_ presentation: Presentation, mapper: CoordinateSpaceMapper) {
        for panel in panels {
            let frame = panel.screen?.frame ?? panel.frame
            panel.contentView = makeContent(presentation, screenFrame: frame, mapper: mapper)
        }
    }

    private func makeContent(
        _ presentation: Presentation,
        screenFrame: CGRect,
        mapper: CoordinateSpaceMapper
    ) -> NSView {
        NSHostingView(rootView: OverlayCanvasView(
            presentation: presentation,
            screenFrame: screenFrame,
            mapper: mapper,
            cursorPositionMonitor: cursorPositionMonitor
        ))
    }

    private func beginCursorMonitoring() {
        guard !isMonitoringCursor else { return }
        isMonitoringCursor = true
        cursorPositionMonitor.beginMonitoring()
    }

    private func endCursorMonitoring() {
        guard isMonitoringCursor else { return }
        isMonitoringCursor = false
        cursorPositionMonitor.endMonitoring()
    }
}

private final class ClickThroughPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct VisualInstruction: Equatable, Sendable {
    let text: String
    let explanation: String?
    let target: GroundedTarget?
    let overlay: OverlayStyle
}
