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

struct AccessibilityService {
    private let interactiveRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXColorWellRole, kAXComboBoxRole,
        kAXDisclosureTriangleRole, kAXIncrementorRole, "AXLink",
        kAXMenuBarItemRole, kAXMenuItemRole, kAXPopUpButtonRole,
        kAXRadioButtonRole, kAXRowRole, kAXSliderRole, kAXTabGroupRole,
        kAXTextAreaRole, kAXTextFieldRole, kAXToolbarRole
    ]

    func isTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func captureScene(includeScreenshot: ScreenSnapshot? = nil) throws -> ScreenScene {
        guard isTrusted() else { throw AccessibilityCaptureError.permissionDenied }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AccessibilityCaptureError.noFrontmostApplication
        }

        let geometry = DisplayGeometryProvider()
        let mapper = geometry.currentMapper()
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let window = copyElementAttribute(appElement, kAXFocusedWindowAttribute)
        var visited = Set<CFHashCode>()
        var elements: [UIElementDescriptor] = []
        walk(
            appElement,
            depth: 0,
            path: "0",
            mapper: mapper,
            visited: &visited,
            output: &elements
        )

        return ScreenScene(
            timestamp: Date(),
            activeApplication: ApplicationDescriptor(
                name: app.localizedName ?? "Unknown application",
                bundleIdentifier: app.bundleIdentifier,
                processIdentifier: app.processIdentifier
            ),
            activeWindow: window.map {
                WindowDescriptor(
                    title: copyStringAttribute($0, kAXTitleAttribute),
                    bounds: rect(of: $0).flatMap(mapper.normalizeAXRect)
                )
            },
            screenshot: includeScreenshot,
            elements: elements,
            displays: geometry.descriptors(using: mapper)
        )
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        path: String,
        mapper: CoordinateSpaceMapper,
        visited: inout Set<CFHashCode>,
        output: inout [UIElementDescriptor]
    ) {
        guard depth <= 12, output.count < 800 else { return }
        let hash = CFHash(element)
        guard visited.insert(hash).inserted else { return }

        let role = copyStringAttribute(element, kAXRoleAttribute)
        let actions = copyActionNames(element)
        let isInteractive = role.map(interactiveRoles.contains) == true || !actions.isEmpty
        let hidden = copyBoolAttribute(element, kAXHiddenAttribute) ?? false

        if isInteractive, !hidden {
            let rawBounds = rect(of: element)
            let normalizedBounds = rawBounds.flatMap(mapper.normalizeAXRect)
            if normalizedBounds != nil {
                output.append(UIElementDescriptor(
                    id: stableID(path: path, role: role, element: element),
                    role: role,
                    subrole: copyStringAttribute(element, kAXSubroleAttribute),
                    label: firstNonEmpty([
                        copyStringAttribute(element, kAXDescriptionAttribute),
                        copyStringAttribute(element, kAXHelpAttribute),
                        copyStringAttribute(element, "AXLabel")
                    ]),
                    title: copyStringAttribute(element, kAXTitleAttribute),
                    value: safeValueString(element),
                    enabled: copyBoolAttribute(element, kAXEnabledAttribute) ?? true,
                    focused: copyBoolAttribute(element, kAXFocusedAttribute) ?? false,
                    bounds: normalizedBounds
                ))
            }
        }

        for (index, child) in copyChildren(element).enumerated() {
            walk(
                child,
                depth: depth + 1,
                path: "\(path).\(index)",
                mapper: mapper,
                visited: &visited,
                output: &output
            )
        }
    }

    private func stableID(path: String, role: String?, element: AXUIElement) -> String {
        var hasher = Hasher()
        hasher.combine(path)
        hasher.combine(role)
        hasher.combine(copyStringAttribute(element, kAXIdentifierAttribute))
        return "e_\(String(UInt(bitPattern: hasher.finalize()), radix: 16).suffix(10))"
    }

    private func rect(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttribute(element, kAXPositionAttribute),
              let sizeValue = copyAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func safeValueString(_ element: AXUIElement) -> String? {
        let subrole = copyStringAttribute(element, kAXSubroleAttribute)
        if subrole == "AXSecureTextField" { return nil }
        guard let value = copyAttribute(element, kAXValueAttribute) else { return nil }
        if let text = value as? String { return String(text.prefix(200)) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func copyActionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(element, kAXChildrenAttribute) else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        copyAttribute(element, attribute) as! AXUIElement?
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private func copyBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (copyAttribute(element, attribute) as? NSNumber)?.boolValue
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
