import AppKit
import Combine

@MainActor
final class CursorPositionMonitor: ObservableObject {
    @Published private(set) var location: CGPoint

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var updateSource: DispatchSourceUserDataAdd?
    private var monitoringClients = 0

    init() {
        location = NSEvent.mouseLocation
    }

    func beginMonitoring() {
        monitoringClients += 1
        guard monitoringClients == 1 else { return }
        location = NSEvent.mouseLocation

        let source = DispatchSource.makeUserDataAddSource(queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.updateLocation() }
        }
        source.resume()
        updateSource = source
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { _ in
            source.add(data: 1)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            self?.updateLocation()
            return event
        }
    }

    func endMonitoring() {
        guard monitoringClients > 0 else { return }
        monitoringClients -= 1
        guard monitoringClients == 0 else { return }
        stopMonitoring()
    }

    deinit {
        updateSource?.cancel()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func stopMonitoring() {
        updateSource?.cancel()
        updateSource = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func updateLocation() {
        let current = NSEvent.mouseLocation
        guard current != location else { return }
        location = current
    }
}
