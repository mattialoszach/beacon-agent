import Foundation

struct RequestModeClassifier {
    func classify(_ request: String) -> InteractionMode {
        let normalized = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let explanatoryPrefixes = [
            "what is", "what's", "what are", "what does",
            "why", "explain", "describe", "tell me about",
            "is this", "are these", "does this", "do we",
            "which model", "how does", "how is"
        ]

        return explanatoryPrefixes.contains(where: normalized.hasPrefix) ? .ask : .guide
    }
}
