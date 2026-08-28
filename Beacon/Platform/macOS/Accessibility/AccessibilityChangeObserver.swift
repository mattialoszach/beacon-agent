import ApplicationServices
import Foundation

enum AccessibilityChangeEvent: Equatable, Sendable {
    case notification(String)
    case fallbackTimer
    case observerUnavailable
}

/// Delivers Accessibility notifications immediately and a low-rate timer event as a
/// fallback for applications that do not publish useful AX notifications.
final class AccessibilityChangeObserver {
    private var observer: AXObserver?
    private var continuation: AsyncStream<AccessibilityChangeEvent>.Continuation?
    private var fallbackTimer: DispatchSourceTimer?
    private var observedElements: [AXUIElement] = []
    private var applicationElement: AXUIElement?

    func events(
        for processIdentifier: Int32,
        fallbackInterval: TimeInterval = 3
    ) -> AsyncStream<AccessibilityChangeEvent> {
        stop()
        var capturedContinuation: AsyncStream<AccessibilityChangeEvent>.Continuation?
        let stream = AsyncStream<AccessibilityChangeEvent>(bufferingPolicy: .bufferingNewest(4)) {
            capturedContinuation = $0
        }
        continuation = capturedContinuation

        if !configureObserver(for: processIdentifier) {
            continuation?.yield(.observerUnavailable)
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + fallbackInterval, repeating: fallbackInterval)
        timer.setEventHandler { [weak self] in
            self?.continuation?.yield(.fallbackTimer)
        }
        timer.resume()
        fallbackTimer = timer
        return stream
    }

    func stop() {
        fallbackTimer?.setEventHandler {}
        fallbackTimer?.cancel()
        fallbackTimer = nil
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        observedElements = []
        applicationElement = nil
        let currentContinuation = continuation
        continuation = nil
        currentContinuation?.finish()
    }

    fileprivate func received(element: AXUIElement, notification: String) {
        continuation?.yield(.notification(notification))
        if notification == kAXFocusedUIElementChangedNotification
            || notification == kAXFocusedWindowChangedNotification
            || notification == kAXWindowCreatedNotification {
            registerDynamicElements()
        }
    }

    private func configureObserver(for processIdentifier: Int32) -> Bool {
        var createdObserver: AXObserver?
        guard AXObserverCreate(processIdentifier, accessibilityChangeCallback, &createdObserver) == .success,
              let createdObserver else { return false }
        observer = createdObserver
        let app = AXUIElementCreateApplication(processIdentifier)
        applicationElement = app
        register(
            app,
            notifications: [
                kAXFocusedUIElementChangedNotification,
                kAXFocusedWindowChangedNotification,
                kAXWindowCreatedNotification,
                kAXMenuOpenedNotification,
                kAXMenuClosedNotification,
                kAXMenuItemSelectedNotification,
                kAXLayoutChangedNotification,
                kAXUIElementDestroyedNotification
            ]
        )
        registerDynamicElements()
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )
        return true
    }

    private func registerDynamicElements() {
        guard let applicationElement else { return }
        if let window = copyElementAttribute(applicationElement, kAXFocusedWindowAttribute) {
            register(
                window,
                notifications: [
                    kAXMovedNotification,
                    kAXResizedNotification,
                    kAXTitleChangedNotification,
                    kAXLayoutChangedNotification,
                    kAXSelectedChildrenChangedNotification,
                    kAXUIElementDestroyedNotification
                ]
            )
        }
        if let focused = copyElementAttribute(applicationElement, kAXFocusedUIElementAttribute) {
            register(
                focused,
                notifications: [
                    kAXValueChangedNotification,
                    kAXSelectedChildrenChangedNotification,
                    kAXSelectedTextChangedNotification,
                    kAXTitleChangedNotification,
                    kAXUIElementDestroyedNotification
                ]
            )
        }
    }

    private func register(_ element: AXUIElement, notifications: [String]) {
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for notification in notifications {
            let result = AXObserverAddNotification(observer, element, notification as CFString, refcon)
            registered = registered || result == .success || result == .notificationAlreadyRegistered
        }
        if registered, !observedElements.contains(where: { CFEqual($0, element) }) {
            observedElements.append(element)
        }
    }

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}

private let accessibilityChangeCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let changeObserver = Unmanaged<AccessibilityChangeObserver>.fromOpaque(refcon).takeUnretainedValue()
    changeObserver.received(element: element, notification: notification as String)
}
