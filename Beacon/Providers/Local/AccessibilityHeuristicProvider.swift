import Foundation

struct AccessibilityHeuristicProvider: InstructorModel {
    let id = "On-device accessibility matcher"
    let capabilities: ModelCapabilities = [.text, .structuredOutput, .local]

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        if request.mode == .ask || looksExplanatory(request.question) {
            return InstructorResponse(
                message: explanation(for: request),
                action: nil,
                expectedOutcome: nil
            )
        }

        guard let match = SemanticElementMatcher.bestMatch(for: request.question, in: request.scene.elements) else {
            return InstructorResponse(
                message: "I couldn't confidently match that request to an accessible control. Open Developer Inspector to see what this app exposes.",
                action: nil,
                expectedOutcome: nil
            )
        }

        return InstructorResponse(
            message: "Select \(match.element.bestLabel).",
            action: SuggestedAction(
                type: .pointToElement,
                targetElementId: match.element.id,
                targetBounds: nil,
                overlay: .spotlight
            ),
            expectedOutcome: ExpectedOutcome(
                type: .visualChange,
                description: "The visible interface should change after selecting \(match.element.bestLabel)."
            )
        )
    }

    private func looksExplanatory(_ question: String) -> Bool {
        let lower = question.lowercased()
        return lower.hasPrefix("what is") || lower.hasPrefix("what does") || lower.hasPrefix("why")
    }

    private func explanation(for request: InstructorRequest) -> String {
        let focused = request.scene.elements.first(where: \.focused)
        if let focused {
            return "The focused control is \(focused.bestLabel) (\(focused.role ?? "UI element"))."
        }
        return "You're in \(request.scene.activeApplication.name) with \(request.scene.elements.count) accessible controls visible."
    }
}
