import Foundation

enum SceneFreshnessIssue: Equatable, Sendable {
    case applicationChanged(expectedApplication: String)
    case windowChanged(expectedWindow: String?, application: String)
    case menuClosed(label: String, application: String)
    case targetUnavailable(label: String, application: String)
    case interfaceChanged(application: String)
    case visualContextUnavailable(application: String)

    var recoveryMessage: String {
        switch self {
        case let .applicationChanged(expectedApplication):
            "Beacon paused because \(expectedApplication) is no longer in front. Return to it and restore the previous screen."
        case let .windowChanged(expectedWindow, application):
            if let expectedWindow, !expectedWindow.isEmpty {
                "Beacon paused because the window changed. Return to “\(expectedWindow)” in \(application)."
            } else {
                "Beacon paused because the window changed. Return to the previous window in \(application)."
            }
        case let .menuClosed(label, _):
            "The menu containing “\(label)” closed while I was checking it. Open that menu again and keep it open for a moment."
        case let .targetUnavailable(label, application):
            "I can no longer see “\(label)” in \(application). Restore the previous view and I’ll continue."
        case let .interfaceChanged(application):
            "The interface changed while I was checking it. Restore the previous view in \(application) and I’ll continue."
        case let .visualContextUnavailable(application):
            "The visible layout changed while I was checking it. Restore the previous view in \(application) and I’ll continue."
        }
    }
}

enum SceneFreshnessResult: Equatable, Sendable {
    case valid(target: GroundedTarget)
    case stale(SceneFreshnessIssue)
}

struct SceneFreshnessValidator: Sendable {
    func contextIssue(source: ScreenScene, latest: ScreenScene) -> SceneFreshnessIssue? {
        guard source.activeApplication.processIdentifier == latest.activeApplication.processIdentifier,
              source.activeApplication.bundleIdentifier == latest.activeApplication.bundleIdentifier else {
            return .applicationChanged(expectedApplication: source.activeApplication.name)
        }
        guard normalized(source.activeWindow?.title) == normalized(latest.activeWindow?.title) else {
            return .windowChanged(
                expectedWindow: source.activeWindow?.title,
                application: source.activeApplication.name
            )
        }
        guard SceneSemanticFingerprint(source) == SceneSemanticFingerprint(latest) else {
            return .interfaceChanged(application: source.activeApplication.name)
        }
        return nil
    }

    func validate(
        source: ScreenScene,
        latest: ScreenScene,
        target: GroundedTarget
    ) -> SceneFreshnessResult {
        guard source.activeApplication.processIdentifier == latest.activeApplication.processIdentifier,
              source.activeApplication.bundleIdentifier == latest.activeApplication.bundleIdentifier else {
            return .stale(.applicationChanged(expectedApplication: source.activeApplication.name))
        }

        guard normalized(source.activeWindow?.title) == normalized(latest.activeWindow?.title) else {
            return .stale(.windowChanged(
                expectedWindow: source.activeWindow?.title,
                application: source.activeApplication.name
            ))
        }

        let refreshedTarget: GroundedTarget
        switch target {
        case let .accessibilityElement(elementID, _):
            let original = source.elements.first(where: { $0.id == elementID })
            guard let current = latest.elements.first(where: { $0.id == elementID }),
                  let bounds = current.bounds,
                  bounds.isValid else {
                let label = original?.bestLabel ?? "the highlighted control"
                let issue: SceneFreshnessIssue = original?.role == "AXMenuItem"
                    ? .menuClosed(label: label, application: source.activeApplication.name)
                    : .targetUnavailable(label: label, application: source.activeApplication.name)
                return .stale(issue)
            }
            guard original.map(ElementIdentity.init) == ElementIdentity(current) else {
                return .stale(.targetUnavailable(
                    label: original?.bestLabel ?? current.bestLabel,
                    application: source.activeApplication.name
                ))
            }
            refreshedTarget = .accessibilityElement(elementId: elementID, bounds: bounds)
        case .visualRegion, .point:
            refreshedTarget = target
        }

        guard SceneSemanticFingerprint(source) == SceneSemanticFingerprint(latest) else {
            return .stale(.interfaceChanged(application: source.activeApplication.name))
        }
        return .valid(target: refreshedTarget)
    }

    private func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct SceneSemanticFingerprint: Equatable {
    let elements: [ElementIdentity]

    init(_ scene: ScreenScene) {
        elements = scene.elements.map(ElementIdentity.init).sorted { $0.id < $1.id }
    }
}

private struct ElementIdentity: Equatable {
    let id: String
    let role: String?
    let subrole: String?
    let label: String?
    let title: String?
    let value: String?
    let enabled: Bool
    let focused: Bool

    init(_ element: UIElementDescriptor) {
        id = element.id
        role = element.role
        subrole = element.subrole
        label = element.label
        title = element.title
        value = element.value
        enabled = element.enabled
        focused = element.focused
    }
}
