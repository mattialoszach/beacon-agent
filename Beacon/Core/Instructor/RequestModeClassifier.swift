import Foundation
import NaturalLanguage

struct RequestModeSemanticScores: Equatable, Sendable {
    let ask: Double
    let guide: Double
}

protocol RequestModeSemanticScoring {
    func scores(for request: String) -> RequestModeSemanticScores?
}

struct NaturalLanguageRequestModeScorer: RequestModeSemanticScoring {
    private let askPrototypes = [
        "Explain what is visible and what it means",
        "Describe this interface or warning",
        "Why is this happening",
        "Tell me information about the current screen"
    ]
    private let guidePrototypes = [
        "Help me perform an action in this application",
        "Show me where to click next",
        "Guide me through completing a task",
        "Find and use a control in the interface"
    ]

    func scores(for request: String) -> RequestModeSemanticScores? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        let askDistance = askPrototypes.map { embedding.distance(between: request, and: $0) }.min() ?? 2
        let guideDistance = guidePrototypes.map { embedding.distance(between: request, and: $0) }.min() ?? 2
        return RequestModeSemanticScores(
            ask: max(0, 1 - askDistance / 2),
            guide: max(0, 1 - guideDistance / 2)
        )
    }
}

struct RequestModeClassification: Equatable, Sendable {
    let mode: InteractionMode
    let confidence: Double
    let askScore: Double
    let guideScore: Double
    let evidence: [String]
}

struct RequestModeClassifier {
    private let semanticScorer: any RequestModeSemanticScoring

    init(semanticScorer: any RequestModeSemanticScoring = NaturalLanguageRequestModeScorer()) {
        self.semanticScorer = semanticScorer
    }

    func classify(_ request: String, scene: ScreenScene? = nil) -> InteractionMode {
        classification(for: request, scene: scene).mode
    }

    func classification(for request: String, scene: ScreenScene? = nil) -> RequestModeClassification {
        let normalized = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let requestTokens = tokens(normalized)
        guard !normalized.isEmpty else {
            return RequestModeClassification(
                mode: .ask,
                confidence: 1,
                askScore: 1,
                guideScore: 0,
                evidence: ["empty request"]
            )
        }

        var askScore = 0.35
        var guideScore = 0.0
        var evidence: [String] = []

        if Self.guidePhrases.contains(where: normalized.hasPrefix) {
            guideScore += 3.4
            evidence.append("action phrasing")
        }
        if Self.explanationPhrases.contains(where: normalized.hasPrefix) {
            askScore += 3.4
            evidence.append("explanation phrasing")
        }

        let actionMatches = requestTokens.intersection(Self.actionVerbs)
        if !actionMatches.isEmpty {
            guideScore += normalizedFirstToken(in: Self.actionVerbs, request: normalized) ? 2.2 : 1.1
            evidence.append("action verb")
        }
        if !requestTokens.intersection(Self.informationWords).isEmpty {
            askScore += 1.0
            evidence.append("information request")
        }
        if normalized.contains("step by step") || normalized.contains("walk me through") {
            guideScore += 2.4
            evidence.append("multi-step request")
        }
        if normalized.contains("what should i do") || normalized.contains("what do i do") {
            guideScore += 2.1
            evidence.append("next-action request")
        }

        if let scene, hasVisibleTarget(for: request, in: scene) {
            guideScore += 0.8
            evidence.append("visible target match")
        }

        if let semantic = semanticScorer.scores(for: request) {
            askScore += semantic.ask * 1.6
            guideScore += semantic.guide * 1.6
            if abs(semantic.ask - semantic.guide) >= 0.08 {
                evidence.append(semantic.guide > semantic.ask ? "semantic action match" : "semantic explanation match")
            }
        }

        let mode: InteractionMode = guideScore > askScore + 0.15 ? .guide : .ask
        let total = max(0.001, askScore + guideScore)
        let confidence = min(0.99, 0.5 + abs(guideScore - askScore) / total * 0.5)
        return RequestModeClassification(
            mode: mode,
            confidence: confidence,
            askScore: askScore,
            guideScore: guideScore,
            evidence: evidence
        )
    }

    private func hasVisibleTarget(for request: String, in scene: ScreenScene) -> Bool {
        if SemanticElementMatcher.bestMatch(for: request, in: scene.elements) != nil { return true }
        if VisualElementMatcher.bestMatch(for: request, in: scene.visualElements) != nil { return true }
        let marks = SetOfMarksBuilder().build(scene: scene)
        return SetOfMarksMatcher.bestMatch(for: request, in: marks) != nil
    }

    private func tokens(_ text: String) -> Set<String> {
        Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private func normalizedFirstToken(in candidates: Set<String>, request: String) -> Bool {
        request.split { !$0.isLetter && !$0.isNumber }.first.map(String.init).map(candidates.contains) == true
    }

    private static let guidePhrases = [
        "how do i", "how can i", "where is", "where can i", "show me", "guide me",
        "help me", "find the", "take me to", "steps to", "can you help me"
    ]

    private static let explanationPhrases = [
        "what is", "what's", "what are", "what does", "why", "explain", "describe",
        "tell me about", "is this", "are these", "does this", "do we", "which model",
        "how does", "how is", "how are", "give me an overview"
    ]

    private static let actionVerbs: Set<String> = [
        "add", "apply", "change", "choose", "click", "close", "configure", "create",
        "delete", "disable", "download", "edit", "enable", "export", "find", "import",
        "insert", "move", "open", "print", "remove", "rename", "save", "select", "send",
        "share", "switch", "turn", "upload", "zoom"
    ]

    private static let informationWords: Set<String> = [
        "explanation", "meaning", "overview", "reason", "summary", "warning"
    ]
}
