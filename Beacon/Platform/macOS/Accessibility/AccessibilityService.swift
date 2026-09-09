import AppKit
import ApplicationServices
import Foundation

enum AccessibilityCaptureError: LocalizedError {
    case permissionDenied
    case noFrontmostApplication

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Beacon needs Accessibility permission to identify controls on screen."
        case .noFrontmostApplication: "No active application is available to inspect."
        }
    }
}

struct AccessibilityApplicationTarget: Sendable {
    let name: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t

    init(application: NSRunningApplication) {
        name = application.localizedName ?? "Unknown application"
        bundleIdentifier = application.bundleIdentifier
        processIdentifier = application.processIdentifier
    }
}

/// Accessibility calls are cross-process IPC and may be slow when the target app is busy.
/// This service keeps them off the main actor and applies both time and element budgets.
struct AccessibilityService: Sendable {
    private let windowIdentities = AccessibilityWindowIdentities()
    private let interactiveRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXColorWellRole, kAXComboBoxRole,
        kAXDisclosureTriangleRole, kAXIncrementorRole, "AXLink",
        kAXMenuBarItemRole, kAXMenuItemRole, kAXPopUpButtonRole,
        kAXRadioButtonRole, kAXRowRole, kAXSliderRole, kAXTabGroupRole,
        kAXTextAreaRole, kAXTextFieldRole, kAXToolbarRole
    ]

    private let rolesWithoutActions: Set<String> = [
        "AXApplication", "AXWindow", "AXGroup", "AXStaticText", "AXImage",
        "AXScrollArea", "AXSplitGroup", "AXSheet", "AXPopover", "AXMenu",
        "AXTable", "AXOutline", "AXColumn", "AXCell", "AXLayoutArea"
    ]

    func isTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func captureScene(
        for target: AccessibilityApplicationTarget,
        includeScreenshot: ScreenSnapshot? = nil
    ) async throws -> ScreenScene {
        try await Task.detached(priority: .userInitiated) {
            try captureSceneSynchronously(for: target, includeScreenshot: includeScreenshot)
        }.value
    }

    private func captureSceneSynchronously(
        for target: AccessibilityApplicationTarget,
        includeScreenshot: ScreenSnapshot?
    ) throws -> ScreenScene {
        guard isTrusted() else { throw AccessibilityCaptureError.permissionDenied }

        AccessibilityMessagingTimeout.applyProcessWideDefault()
        let geometry = DisplayGeometryProvider()
        let mapper = geometry.currentMapper()
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, AccessibilityMessagingTimeout.seconds)
        let window = copyElementAttribute(appElement, kAXFocusedWindowAttribute)
        let focusedWindowID = window.map(windowIdentities.id(for:))
        var traversal = AccessibilityTraversalBudget()
        var elements: [UIElementDescriptor] = []
        var windows: [WindowDescriptor] = []
        walk(
            appElement,
            depth: 0,
            path: "0",
            windowID: nil,
            mapper: mapper,
            traversal: &traversal,
            output: &elements,
            windows: &windows
        )

        // Secure fields in the application's other visible windows are still on the
        // captured display, so their masks are collected before the focused-window filter.
        let secureFieldBounds = elements.compactMap { element in
            element.subrole == "AXSecureTextField" ? element.bounds : nil
        }
        let relatedWindowIDs = SceneIdentity.windowIDs(
            relatedTo: focusedWindowID,
            in: windows
        )

        return ScreenScene(
            timestamp: Date(),
            activeApplication: ApplicationDescriptor(
                name: target.name,
                bundleIdentifier: target.bundleIdentifier,
                processIdentifier: target.processIdentifier
            ),
            activeWindow: window.map {
                let values = attributes(of: $0).values
                return WindowDescriptor(
                    title: stringAttribute(kAXTitleAttribute, in: values),
                    bounds: rect(in: values).flatMap { mapper.normalizeAXRect(clippingToDesktop: $0) },
                    id: focusedWindowID,
                    role: stringAttribute(kAXRoleAttribute, in: values)
                )
            },
            screenshot: includeScreenshot,
            elements: elements.filter { element in
                guard let id = element.windowID else { return true }
                return relatedWindowIDs.contains(id)
            },
            displays: geometry.descriptors(using: mapper),
            windows: windows,
            secureFieldBounds: secureFieldBounds,
            isTruncated: traversal.didTruncate
        )
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        path: String,
        windowID: String?,
        mapper: CoordinateSpaceMapper,
        traversal: inout AccessibilityTraversalBudget,
        output: inout [UIElementDescriptor],
        windows: inout [WindowDescriptor]
    ) {
        guard depth <= AccessibilityTraversalBudget.maximumDepth else {
            traversal.noteTruncated()
            return
        }
        guard output.count < AccessibilityTraversalBudget.maximumOutputElements else {
            traversal.noteTruncated()
            return
        }
        guard traversal.beginVisit(element) else { return }

        let read = attributes(of: element)
        guard !read.timedOut else {
            // The element did not answer in time. Its own attributes and its children are
            // both unreadable, and any further read would stall for the same timeout.
            traversal.noteTruncated()
            return
        }
        let values = read.values
        guard !(boolAttribute(kAXHiddenAttribute, in: values) ?? false) else { return }
        let role = stringAttribute(kAXRoleAttribute, in: values)
        var owningWindowID = windowID
        if role == "AXWindow" || role == "AXSheet" {
            owningWindowID = windowIdentities.id(for: element)
            windows.append(WindowDescriptor(
                title: stringAttribute(kAXTitleAttribute, in: values),
                bounds: rect(in: values).flatMap { mapper.normalizeAXRect(clippingToDesktop: $0) },
                id: owningWindowID, role: role, parentWindowID: windowID
            ))
        }
        let hasKnownInteractiveRole = role.map(interactiveRoles.contains) == true
        let shouldInspectActions = role.map { !rolesWithoutActions.contains($0) } ?? true
        let isInteractive = hasKnownInteractiveRole || (shouldInspectActions && !copyActionNames(element).isEmpty)

        if isInteractive, !(boolAttribute(kAXHiddenAttribute, in: values) ?? false),
           let normalizedBounds = rect(in: values)
            .flatMap({ mapper.normalizeAXRect(clippingToDesktop: $0) }),
           normalizedBounds.width > 0.000_1,
           normalizedBounds.height > 0.000_1 {
            let subrole = stringAttribute(kAXSubroleAttribute, in: values)
            output.append(UIElementDescriptor(
                id: stableID(
                    path: "\(owningWindowID ?? "menu"):\(path)",
                    role: role,
                    identifier: stringAttribute(kAXIdentifierAttribute, in: values)
                ),
                role: role,
                subrole: subrole,
                label: firstNonEmpty([
                    stringAttribute(kAXDescriptionAttribute, in: values),
                    stringAttribute(kAXHelpAttribute, in: values),
                    stringAttribute("AXLabel", in: values)
                ]),
                title: stringAttribute(kAXTitleAttribute, in: values),
                value: safeValueString(value(in: values, for: kAXValueAttribute), subrole: subrole),
                enabled: boolAttribute(kAXEnabledAttribute, in: values) ?? true,
                focused: boolAttribute(kAXFocusedAttribute, in: values) ?? false,
                bounds: normalizedBounds,
                windowID: owningWindowID,
                selected: boolAttribute(kAXSelectedAttribute, in: values)
            ))
        }

        for (index, child) in elementArrayAttribute(kAXChildrenAttribute, in: values).enumerated() {
            walk(
                child,
                depth: depth + 1,
                path: "\(path).\(index)",
                windowID: owningWindowID,
                mapper: mapper,
                traversal: &traversal,
                output: &output,
                windows: &windows
            )
            guard traversal.canContinue,
                  output.count < AccessibilityTraversalBudget.maximumOutputElements else {
                traversal.noteTruncated()
                return
            }
        }
    }

    private func stableID(path: String, role: String?, identifier: String?) -> String {
        var hasher = Hasher()
        hasher.combine(path)
        hasher.combine(role)
        hasher.combine(identifier)
        return "e_\(String(UInt(bitPattern: hasher.finalize()), radix: 16).suffix(10))"
    }

    private func rect(in attributes: [String: Any]) -> CGRect? {
        guard let positionValue = value(in: attributes, for: kAXPositionAttribute),
              let sizeValue = value(in: attributes, for: kAXSizeAttribute),
              CFGetTypeID(positionValue as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func safeValueString(_ value: Any?, subrole: String?) -> String? {
        if subrole == "AXSecureTextField" { return nil }
        if let text = value as? String { return String(text.prefix(200)) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func copyActionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func attributes(
        of element: AXUIElement
    ) -> (values: [String: Any], timedOut: Bool) {
        let names = Self.capturedAttributeNames
        var copiedValues: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            names as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &copiedValues
        )
        guard status == .success,
        let values = copiedValues as? [Any],
        values.count == names.count else {
            // A timed-out element times out again on every individual read, so the
            // per-attribute fallback would multiply one stall by the attribute count.
            guard status != .cannotComplete else { return ([:], true) }
            let fallback = Dictionary(uniqueKeysWithValues: names.compactMap { name in
                copyAttribute(element, name).map { (name, $0) }
            })
            return (fallback, false)
        }
        let pairs: [(String, Any)] = zip(names, values).compactMap { name, value in
            guard !(value is NSNull), !isAccessibilityError(value) else { return nil }
            return (name, value)
        }
        return (Dictionary(uniqueKeysWithValues: pairs), false)
    }

    private func isAccessibilityError(_ value: Any) -> Bool {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return false }
        return AXValueGetType(value as! AXValue) == .axError
    }

    private func value(in attributes: [String: Any], for name: String) -> Any? {
        attributes[name]
    }

    private func stringAttribute(_ name: String, in attributes: [String: Any]) -> String? {
        value(in: attributes, for: name) as? String
    }

    private func boolAttribute(_ name: String, in attributes: [String: Any]) -> Bool? {
        (value(in: attributes, for: name) as? NSNumber)?.boolValue
    }

    private func elementArrayAttribute(_ name: String, in attributes: [String: Any]) -> [AXUIElement] {
        value(in: attributes, for: name) as? [AXUIElement] ?? []
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static let capturedAttributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
        "AXLabel", kAXTitleAttribute, kAXValueAttribute, kAXEnabledAttribute,
        kAXFocusedAttribute, kAXHiddenAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXIdentifierAttribute, kAXChildrenAttribute, kAXSelectedAttribute
    ]
}

/// Keeps process-local window identities across captures without relying on titles or private AX APIs.
private final class AccessibilityWindowIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(element: AXUIElement, id: String)] = []

    func id(for element: AXUIElement) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let index = entries.firstIndex(where: { CFEqual($0.element, element) }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.id
        }
        let id = "w_\(UUID().uuidString)"
        entries.append((element, id))
        if entries.count > 256 { entries.removeFirst(entries.count - 256) }
        return id
    }
}

/// Accessibility reads are synchronous cross-process IPC. Without an explicit timeout a
/// busy or unresponsive target application blocks the caller for the multi-second system
/// default, which would freeze Escape handling and overlay updates.
enum AccessibilityMessagingTimeout {
    static let seconds: Float = 0.25

    private static let applied: Bool = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
        return true
    }()

    /// Sets the process-wide default once. Elements created later inherit it.
    static func applyProcessWideDefault() {
        _ = applied
    }
}

private struct AccessibilityTraversalBudget {
    static let maximumDepth = 12
    static let maximumVisitedElements = 1_200
    static let maximumOutputElements = 500
    static let maximumDuration: TimeInterval = 1.5

    private var visited = Set<CFHashCode>()
    private var visitedCount = 0
    private let deadline = Date().addingTimeInterval(maximumDuration)
    private(set) var didTruncate = false

    var canContinue: Bool {
        visitedCount < Self.maximumVisitedElements && Date() < deadline
    }

    mutating func noteTruncated() {
        didTruncate = true
    }

    mutating func beginVisit(_ element: AXUIElement) -> Bool {
        guard canContinue else {
            didTruncate = true
            return false
        }
        let hash = CFHash(element)
        // A repeated element is a traversal cycle, not a budget limit.
        guard visited.insert(hash).inserted else { return false }
        visitedCount += 1
        return true
    }
}
