import Foundation

struct UIIntention: Codable, Equatable, Sendable {
    let question: String
    let preferredElementID: String?
    let preferredBounds: NormalizedRect?
}

enum GroundedTarget: Codable, Equatable, Sendable {
    case accessibilityElement(elementId: String, bounds: NormalizedRect)
    case visualRegion(bounds: NormalizedRect)
    case point(position: NormalizedPoint)

    var bounds: NormalizedRect? {
        switch self {
        case let .accessibilityElement(_, bounds), let .visualRegion(bounds): bounds
        case let .point(position):
            NormalizedRect.clamped(x: position.x - 0.005, y: position.y - 0.005, width: 0.01, height: 0.01)
        }
    }
}

protocol GroundingStrategy {
    var name: String { get }
    func resolve(intention: UIIntention, scene: ScreenScene) async throws -> GroundingResult
}

struct GroundingResult: Equatable, Sendable {
    let target: GroundedTarget
    let confidence: Double
    let strategy: String
}

enum GroundingError: LocalizedError, Equatable {
    case invalidBounds
    case elementNotFound(String)
    case noCandidate

    var errorDescription: String? {
        switch self {
        case .invalidBounds: "The model returned target bounds outside the screen."
        case let .elementNotFound(id): "The target element \(id) is no longer visible."
        case .noCandidate: "No visible UI element matched the request."
        }
    }
}

struct AccessibilityGrounder: GroundingStrategy {
    let name = "Accessibility"

    func resolve(intention: UIIntention, scene: ScreenScene) async throws -> GroundingResult {
        if let id = intention.preferredElementID {
            guard let element = scene.elements.first(where: { $0.id == id }) else {
                throw GroundingError.elementNotFound(id)
            }
            guard let bounds = element.bounds, bounds.isValid else { throw GroundingError.invalidBounds }
            return .init(
                target: .accessibilityElement(elementId: id, bounds: bounds),
                confidence: 1,
                strategy: name
            )
        }

        if let bounds = intention.preferredBounds {
            guard bounds.isValid else { throw GroundingError.invalidBounds }
            return .init(
                target: .visualRegion(bounds: bounds),
                confidence: 0.75,
                strategy: "Visual bounding box"
            )
        }

        guard let match = SemanticElementMatcher.bestMatch(for: intention.question, in: scene.elements),
              let bounds = match.element.bounds else { throw GroundingError.noCandidate }
        return .init(
            target: .accessibilityElement(elementId: match.element.id, bounds: bounds),
            confidence: match.score,
            strategy: name
        )
    }
}

/// Resolves model-produced bounding boxes after local validation. A vision provider can
/// supply the intention without changing the overlay layer.
struct VisualGrounder: GroundingStrategy {
    let name = "Visual"

    func resolve(intention: UIIntention, scene: ScreenScene) async throws -> GroundingResult {
        guard let bounds = intention.preferredBounds, bounds.isValid else {
            throw GroundingError.invalidBounds
        }
        return GroundingResult(target: .visualRegion(bounds: bounds), confidence: 0.7, strategy: name)
    }
}

struct HybridGrounder: GroundingStrategy {
    let name = "Hybrid"
    let accessibility = AccessibilityGrounder()
    let visual = VisualGrounder()

    func resolve(intention: UIIntention, scene: ScreenScene) async throws -> GroundingResult {
        do { return try await accessibility.resolve(intention: intention, scene: scene) }
        catch where intention.preferredBounds != nil {
            return try await visual.resolve(intention: intention, scene: scene)
        }
    }
}

enum SemanticElementMatcher {
    struct Match: Equatable {
        let element: UIElementDescriptor
        let score: Double
    }

    private static let stopWords: Set<String> = [
        "a", "about", "an", "can", "do", "does", "how", "i", "is", "me", "my",
        "of", "on", "please", "the", "this", "to", "where", "with"
    ]

    private static let synonyms: [String: Set<String>] = [
        "export": ["export", "share", "download", "save"],
        "preferences": ["preferences", "settings", "options"],
        "format": ["format", "type", "kind"],
        "close": ["close", "cancel", "done"],
        "open": ["open", "choose", "select"],
        "print": ["print", "printer"]
    ]

    static func bestMatch(for question: String, in elements: [UIElementDescriptor]) -> Match? {
        let queryTokens = expandedTokens(question)
        guard !queryTokens.isEmpty else { return nil }

        return elements.compactMap { element -> Match? in
            guard element.enabled, element.bounds?.isValid == true else { return nil }
            let candidate = [element.label, element.title, element.value, element.role]
                .compactMap { $0 }
                .joined(separator: " ")
            let candidateTokens = expandedTokens(candidate)
            let overlap = queryTokens.intersection(candidateTokens)
            guard !overlap.isEmpty else { return nil }
            let exactPhrase = candidate.lowercased().contains(question.lowercased()) ? 0.25 : 0
            let score = min(1, Double(overlap.count) / Double(max(1, queryTokens.count)) + exactPhrase + 0.35)
            return Match(element: element, score: score)
        }
        .max { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.element.bestLabel.count > rhs.element.bestLabel.count
                : lhs.score < rhs.score
        }
    }

    private static func expandedTokens(_ text: String) -> Set<String> {
        let raw = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .subtracting(stopWords)
        return raw.reduce(into: raw) { result, token in
            for group in synonyms.values where group.contains(token) { result.formUnion(group) }
        }
    }
}
