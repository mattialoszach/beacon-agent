import ApplicationServices
import Foundation

enum AccessibilityChangeEvent: Equatable, Sendable {
    case notification(name: String, role: String?, label: String?)
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
        let details = notification == kAXMenuOpenedNotification
            ? observedIdentity(of: element)
            : (role: nil, label: nil)
        continuation?.yield(.notification(
            name: notification,
            role: details.role,
            label: details.label
        ))
        if notification == kAXFocusedUIElementChangedNotification
            || notification == kAXFocusedWindowChangedNotification
            || notification == kAXWindowCreatedNotification {
            registerDynamicElements()
        }
    }

    private func configureObserver(for processIdentifier: Int32) -> Bool {
        AccessibilityMessagingTimeout.applyProcessWideDefault()
        var createdObserver: AXObserver?
        guard AXObserverCreate(processIdentifier, accessibilityChangeCallback, &createdObserver) == .success,
              let createdObserver else { return false }
        observer = createdObserver
        let app = AXUIElementCreateApplication(processIdentifier)
        // Registration and the callback below run on the main run loop, so every read
        // must be bounded or an unresponsive target application freezes Beacon's UI.
        AXUIElementSetMessagingTimeout(app, AccessibilityMessagingTimeout.seconds)
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
        let copied = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(copied, AccessibilityMessagingTimeout.seconds)
        return copied
    }

    /// The AX tree in Electron applications can expose closed-menu descendants, making
    /// before/after tree comparison inconclusive. The menu-open callback itself carries
    /// the opened menu; retain only its short role/label so the controller can confirm it
    /// was the highlighted menu rather than an unrelated one.
    private func observedIdentity(of element: AXUIElement) -> (role: String?, label: String?) {
        AXUIElementSetMessagingTimeout(element, AccessibilityMessagingTimeout.seconds)
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"]
        var copiedValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            names as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &copiedValues
        ) == .success,
        let values = copiedValues as? [Any], values.count == names.count else {
            return (nil, nil)
        }
        func string(at index: Int) -> String? {
            guard !(values[index] is NSNull) else { return nil }
            return values[index] as? String
        }
        let label = [string(at: 1), string(at: 2), string(at: 3)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return (string(at: 0), label)
    }
}

private let accessibilityChangeCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let changeObserver = Unmanaged<AccessibilityChangeObserver>.fromOpaque(refcon).takeUnretainedValue()
    changeObserver.received(element: element, notification: notification as String)
}
