import Foundation

enum SceneFreshnessIssue: Equatable, Sendable {
    case displaysChanged
    case applicationChanged(expectedApplication: String)
    case windowChanged(expectedWindow: String?, application: String)
    case menuClosed(label: String, application: String)
    case targetUnavailable(label: String, application: String)
    case interfaceChanged(application: String)
    case visualContextUnavailable(application: String)

    var recoveryMessage: String {
        switch self {
        case .displaysChanged:
            "The display layout changed. Start a new request so Beacon can locate the controls again."
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
    case inconclusive
}

enum SceneContextFreshnessResult: Equatable, Sendable {
    case valid
    case stale(SceneFreshnessIssue)
    case inconclusive
}

struct SceneFreshnessValidator: Sendable {
    func contextStatus(source: ScreenScene, latest: ScreenScene) -> SceneContextFreshnessResult {
        guard SceneIdentity.sameDisplays(source, latest) else { return .stale(.displaysChanged) }
        guard source.activeApplication.processIdentifier == latest.activeApplication.processIdentifier,
              source.activeApplication.bundleIdentifier == latest.activeApplication.bundleIdentifier else {
            return .stale(.applicationChanged(expectedApplication: source.activeApplication.name))
        }
        guard SceneIdentity.sameWindow(source.activeWindow, latest.activeWindow) else {
            return .stale(.windowChanged(
                expectedWindow: source.activeWindow?.title,
                application: source.activeApplication.name
            ))
        }
        guard !source.isTruncated, !latest.isTruncated else {
            return .inconclusive
        }
        guard !isSemanticallyDifferent(source: source, latest: latest) else {
            return .stale(.interfaceChanged(application: source.activeApplication.name))
        }
        return .valid
    }

    func validate(
        source: ScreenScene,
        latest: ScreenScene,
        target: GroundedTarget
    ) -> SceneFreshnessResult {
        guard SceneIdentity.sameDisplays(source, latest) else { return .stale(.displaysChanged) }
        guard source.activeApplication.processIdentifier == latest.activeApplication.processIdentifier,
              source.activeApplication.bundleIdentifier == latest.activeApplication.bundleIdentifier else {
            return .stale(.applicationChanged(expectedApplication: source.activeApplication.name))
        }

        guard SceneIdentity.sameWindow(source.activeWindow, latest.activeWindow) else {
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
            guard current.enabled,
                  original.map(ElementIdentity.init) == ElementIdentity(current) else {
                return .stale(.targetUnavailable(
                    label: original?.bestLabel ?? current.bestLabel,
                    application: source.activeApplication.name
                ))
            }
            refreshedTarget = .accessibilityElement(elementId: elementID, bounds: bounds)

            // A bounded AX walk can be incomplete in large applications even though it
            // captured the requested control. For an Accessibility target, the current
            // app/window/display identity plus the target's stable identity, enabled
            // state, and fresh bounds are sufficient to present it safely. Requiring a
            // complete second walk here makes the same large hierarchy fail forever.
            if source.isTruncated || latest.isTruncated {
                return .valid(target: refreshedTarget)
            }
        case .visualRegion, .point:
            guard source.activeWindow?.bounds == latest.activeWindow?.bounds else {
                return .stale(.visualContextUnavailable(application: source.activeApplication.name))
            }
            refreshedTarget = target
        }

        // Visual targets and whole-interface comparisons still fail closed because an
        // incomplete AX tree cannot establish that their surrounding context is stable.
        guard !source.isTruncated, !latest.isTruncated else {
            return .inconclusive
        }
        guard !isSemanticallyDifferent(source: source, latest: latest) else {
            return .stale(.interfaceChanged(application: source.activeApplication.name))
        }
        return .valid(target: refreshedTarget)
    }

    private func isSemanticallyDifferent(source: ScreenScene, latest: ScreenScene) -> Bool {
        return SceneSemanticFingerprint(source).isMateriallyDifferent(
            from: SceneSemanticFingerprint(latest)
        )
    }
}

private struct SceneSemanticFingerprint {
    private static let maximumToleratedDifferenceRatio = 0.25
    let elementCounts: [ElementIdentity: Int]

    init(_ scene: ScreenScene) {
        elementCounts = scene.elements.reduce(into: [:]) { counts, element in
            counts[ElementIdentity(element), default: 0] += 1
        }
    }

    func isMateriallyDifferent(from other: SceneSemanticFingerprint) -> Bool {
        let sourceCount = elementCounts.values.reduce(0, +)
        let latestCount = other.elementCounts.values.reduce(0, +)
        let maximumCount = max(sourceCount, latestCount)
        guard maximumCount > 0 else { return false }

        let sharedCount = elementCounts.reduce(into: 0) { count, entry in
            count += min(entry.value, other.elementCounts[entry.key, default: 0])
        }
        let differenceRatio = Double(maximumCount - sharedCount) / Double(maximumCount)
        return differenceRatio > Self.maximumToleratedDifferenceRatio
    }
}

private struct ElementIdentity: Equatable, Hashable {
    let windowID: String?
    let role: String?
    let subrole: String?
    let label: String?
    let title: String?

    init(_ element: UIElementDescriptor) {
        windowID = element.windowID
        role = Self.normalized(element.role)
        subrole = Self.normalized(element.subrole)
        label = Self.normalized(element.label)
        title = Self.normalized(element.title)
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
