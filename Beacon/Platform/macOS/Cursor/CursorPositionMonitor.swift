import AppKit
import Combine

@MainActor
final class CursorPositionMonitor: ObservableObject {
    @Published private(set) var location: CGPoint

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {
        location = NSEvent.mouseLocation
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor in self?.updateLocation() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            self?.updateLocation()
            return event
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func updateLocation() {
        let current = NSEvent.mouseLocation
        guard current != location else { return }
        location = current
    }
}
