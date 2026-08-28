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
    let overlay: OverlayStyle

    func validated(in scene: ScreenScene) throws -> SuggestedAction {
        if let id = targetElementId, !scene.elements.contains(where: { $0.id == id }) {
            throw GroundingError.elementNotFound(id)
        }
        if let bounds = targetBounds, !bounds.isValid { throw GroundingError.invalidBounds }
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

struct ExpectedOutcome: Codable, Equatable, Sendable {
    let type: ExpectedOutcomeType
    let description: String
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
