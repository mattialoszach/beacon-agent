import Foundation

enum OverlayStyle: String, Codable, CaseIterable, Sendable {
    case arrow
    case rectangle
    case circle
    case spotlight
    case tooltip
    case numberedBadge
}

enum ActionType: String, Codable, Sendable {
    case pointToElement
    case explain
    case complete
}

struct SuggestedAction: Codable, Equatable, Sendable {
    let type: ActionType
    let targetElementId: String?
    let targetBounds: NormalizedRect?
    var targetMark: Int? = nil
    let overlay: OverlayStyle

    func validated(in scene: ScreenScene, marks: [SetOfMark] = []) throws -> SuggestedAction {
        guard type == .pointToElement else { return self }
        if let id = targetElementId, !scene.elements.contains(where: { $0.id == id }) {
            throw GroundingError.elementNotFound(id)
        }
        if let bounds = targetBounds {
            guard bounds.isValid, bounds.isOnAnyDisplay(of: scene) else {
                throw GroundingError.invalidBounds
            }
        }
        if let targetMark {
            guard let mark = marks.first(where: { $0.id == targetMark }) else {
                throw GroundingError.markNotFound(targetMark)
            }
            guard mark.bounds.isValid else { throw GroundingError.invalidBounds }
        }
        if targetElementId == nil, targetBounds == nil, targetMark == nil {
            throw GroundingError.noCandidate
        }
        return self
    }
}

enum ExpectedOutcomeType: String, Codable, Sendable {
    case windowAppears
    case windowDisappears
    case focusedElementChanges
    case elementAppears
    case visualChange
}

enum ExpectedApplicationScope: String, Codable, Sendable {
    case sameApplication
    case mayChange
}

struct ExpectedOutcome: Codable, Equatable, Sendable {
    let type: ExpectedOutcomeType
    let description: String
    let applicationScope: ExpectedApplicationScope
    let element: ExpectedElement?
    let windowTitle: String?
    let destinationBundleIdentifier: String?

    init(
        type: ExpectedOutcomeType,
        description: String,
        applicationScope: ExpectedApplicationScope = .sameApplication,
        element: ExpectedElement? = nil,
        windowTitle: String? = nil,
        destinationBundleIdentifier: String? = nil
    ) {
        self.type = type
        self.description = description
        self.applicationScope = applicationScope
        self.element = element
        self.windowTitle = windowTitle
        self.destinationBundleIdentifier = destinationBundleIdentifier
    }

    var canVerifyAutomatically: Bool {
        if applicationScope == .mayChange,
           destinationBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return false }
        switch type {
        case .windowDisappears: return false // Save and Cancel can produce the same visible state.
        case .windowAppears: return windowTitle.map { !ExpectedElement.normalized($0).isEmpty } == true || element?.hasIdentity == true
        case .elementAppears, .focusedElementChanges: return element?.hasIdentity == true
        case .visualChange: return element?.hasIdentity == true && element?.value != nil
        }
    }
}

struct ExpectedElement: Codable, Equatable, Sendable {
    var id: String? = nil
    var labels: [String] = []
    var role: String? = nil
    var value: String? = nil

    var hasIdentity: Bool {
        id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || labels.contains { !Self.normalized($0).isEmpty }
    }

    func matches(_ element: UIElementDescriptor, includingValue: Bool = true) -> Bool {
        guard hasIdentity else { return false }
        if let id, id != element.id { return false }
        if let role, role != element.role { return false }
        if !labels.isEmpty, !labels.contains(where: { label in
            [element.label, element.title].compactMap { $0 }.contains { Self.normalized($0) == Self.normalized(label) }
        }) { return false }
        if includingValue, let value, Self.normalized(element.value ?? "") != Self.normalized(value) { return false }
        return true
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ":."))
    }
}

struct InstructorResponse: Codable, Equatable, Sendable {
    let message: String
    let action: SuggestedAction?
    let expectedOutcome: ExpectedOutcome?
    var taskComplete: Bool? = nil
}

extension InstructorResponse {
    func normalizingVisualTarget(in scene: ScreenScene) -> InstructorResponse {
        guard let action,
              let id = action.targetElementId,
              let visual = scene.visualElements.first(where: { $0.id == id }) else { return self }
        return InstructorResponse(
            message: message,
            action: SuggestedAction(
                type: action.type,
                targetElementId: nil,
                targetBounds: visual.bounds,
                targetMark: action.targetMark,
                overlay: action.overlay
            ),
            expectedOutcome: expectedOutcome,
            taskComplete: taskComplete
        )
    }
}

struct InstructorRequest: Codable, Equatable, Sendable {
    let question: String
    let scene: ScreenScene
    let mode: InteractionMode
    var guideContext: GuideContext? = nil
    var setOfMarks: [SetOfMark] = []
    var visualContextImage: ScreenSnapshot? = nil
}

struct CompletedGuideStep: Codable, Equatable, Sendable {
    let number: Int
    let instruction: String
    let targetElementID: String?
    let targetLabel: String?
}

struct GuideContext: Codable, Equatable, Sendable {
    let stepNumber: Int
    let maximumSteps: Int
    let completedSteps: [CompletedGuideStep]
}

enum InteractionMode: String, Codable, CaseIterable, Sendable {
    case ask = "Ask"
    case guide = "Guide"
    case agent = "Agent (future)"
}

struct ModelCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let text = ModelCapabilities(rawValue: 1 << 0)
    static let vision = ModelCapabilities(rawValue: 1 << 1)
    static let structuredOutput = ModelCapabilities(rawValue: 1 << 2)
    static let local = ModelCapabilities(rawValue: 1 << 3)
}

protocol InstructorModel {
    var id: String { get }
    var capabilities: ModelCapabilities { get }
    func reason(request: InstructorRequest) async throws -> InstructorResponse
}

protocol ModelRouting {
    func selectModel(for request: InstructorRequest) -> any InstructorModel
}
