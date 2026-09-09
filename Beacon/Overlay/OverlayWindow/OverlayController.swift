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

    private struct OverlayPanel {
        let panel: NSPanel
        let hostingView: NSHostingView<OverlayCanvasView>
        /// The screen frame this panel was built for, in global AppKit coordinates.
        let screenFrame: CGRect
    }

    private var panels: [OverlayPanel] = []
    private let cursorPositionMonitor: CursorPositionMonitor
    private let isEnabled: Bool
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var isMonitoringCursor = false
    private var cursorMovementBaseline: UInt64 = 0
    private(set) var presentation: Presentation?
    var onDismiss: (() -> Void)?

    init(isEnabled: Bool = true) {
        cursorPositionMonitor = CursorPositionMonitor()
        self.isEnabled = isEnabled
    }

    init(cursorPositionMonitor: CursorPositionMonitor, isEnabled: Bool = true) {
        self.cursorPositionMonitor = cursorPositionMonitor
        self.isEnabled = isEnabled
    }

    func showInstruction(_ instruction: VisualInstruction) {
        show(Presentation(
            target: instruction.target,
            instruction: [instruction.text, instruction.explanation].compactMap { $0 }.joined(separator: "\n"),
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
        panels.forEach { $0.panel.orderOut(nil) }
        panels.removeAll()
        presentation = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        escapeMonitor = nil
        localEscapeMonitor = nil
        endCursorMonitoring()
    }

    private func show(_ presentation: Presentation) {
        guard isEnabled else { return }
        self.presentation = presentation
        cursorMovementBaseline = cursorPositionMonitor.presentationBaseline()
        let mapper = DisplayGeometryProvider().currentMapper()

        if !panels.isEmpty {
            render(presentation, mapper: mapper)
            return
        }

        beginCursorMonitoring()

        for screen in NSScreen.screens {
            let panel = Self.makeOverlayPanel(screenFrame: screen.frame)
            let hostingView = makeContent(presentation, screenFrame: screen.frame, mapper: mapper)
            panel.contentView = hostingView
            panel.orderFrontRegardless()
            panels.append(
                OverlayPanel(panel: panel, hostingView: hostingView, screenFrame: screen.frame)
            )
        }

        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == EscapeRouting.keyCode else { return }
            Task { @MainActor in
                self?.dismiss()
                self?.onDismiss?()
            }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == EscapeRouting.keyCode, let self,
                  self.handlesEscape(from: event.window) else {
                return event
            }
            self.dismiss()
            self.onDismiss?()
            return nil
        }
    }

    /// Builds one transparent, click-through panel covering a screen.
    ///
    /// `contentRect` is in global AppKit coordinates here. The `screen:` variant of this
    /// initializer treats the rectangle as screen-relative, which places every panel on a
    /// secondary display at twice that display's origin, off the virtual desktop.
    static func makeOverlayPanel(screenFrame: CGRect) -> NSPanel {
        let panel = ClickThroughPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.setFrame(screenFrame, display: false)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Release-blocking invariant: guidance must never intercept normal mouse input.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    /// Overlay panels never become key, so the key window here is normally one of Beacon's
    /// ordinary windows; a dialog in front of the user keeps its own Escape.
    private func handlesEscape(from window: NSWindow?) -> Bool {
        if let window, panels.contains(where: { $0.panel === window }) { return true }
        return EscapeRouting.handlesEscape(from: window)
    }

    private func update(_ presentation: Presentation) {
        // Observation ticks re-send an unchanged target; rebuilding the tree then would
        // restart animations and repaint every display for nothing.
        guard presentation != self.presentation else { return }
        self.presentation = presentation
        render(presentation, mapper: DisplayGeometryProvider().currentMapper())
    }

    private func render(_ presentation: Presentation, mapper: CoordinateSpaceMapper) {
        for overlay in panels {
            overlay.hostingView.rootView = OverlayCanvasView(
                presentation: presentation,
                screenFrame: overlay.screenFrame,
                mapper: mapper,
                cursorPositionMonitor: cursorPositionMonitor,
                cursorMovementBaseline: cursorMovementBaseline
            )
        }
    }

    private func makeContent(
        _ presentation: Presentation,
        screenFrame: CGRect,
        mapper: CoordinateSpaceMapper
    ) -> NSHostingView<OverlayCanvasView> {
        NSHostingView(rootView: OverlayCanvasView(
            presentation: presentation,
            screenFrame: screenFrame,
            mapper: mapper,
            cursorPositionMonitor: cursorPositionMonitor,
            cursorMovementBaseline: cursorMovementBaseline
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
