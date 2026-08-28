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

        let completedIDs = Set(request.guideContext?.completedSteps.compactMap(\.targetElementID) ?? [])
        let completedLabels = Set(request.guideContext?.completedSteps.compactMap { $0.targetLabel?.lowercased() } ?? [])
        let availableElements = request.scene.elements.filter {
            !completedIDs.contains($0.id) && !completedLabels.contains($0.bestLabel.lowercased())
        }
        guard let match = SemanticElementMatcher.bestMatch(for: request.question, in: availableElements)
            ?? navigationFallback(for: request.question, in: availableElements) else {
            if let visual = VisualElementMatcher.bestMatch(for: request.question, in: request.scene.visualElements) {
                return InstructorResponse(
                    message: "Select \(visual.element.text).",
                    action: SuggestedAction(
                        type: .pointToElement,
                        targetElementId: nil,
                        targetBounds: visual.element.bounds,
                        overlay: .rectangle
                    ),
                    expectedOutcome: ExpectedOutcome(
                        type: .visualChange,
                        description: "The visible interface should change after selecting \(visual.element.text)."
                    )
                )
            }
            return InstructorResponse(
                message: request.guideContext?.completedSteps.isEmpty == false
                    ? "The previous steps are complete and I don't see another matching control. The task may be finished."
                    : "I couldn't confidently match that request to an accessible or visible control. Try naming the control or action more specifically.",
                action: nil,
                expectedOutcome: nil,
                taskComplete: request.guideContext?.completedSteps.isEmpty == false
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

    private func navigationFallback(
        for question: String,
        in elements: [UIElementDescriptor]
    ) -> SemanticElementMatcher.Match? {
        let lower = question.lowercased()
        if ["export", "save", "print", "open", "document", "pdf"].contains(where: lower.contains),
           let file = elements.first(where: {
               $0.enabled && $0.bounds != nil
                   && ["file", "document"].contains($0.bestLabel.lowercased())
           }) {
            return .init(element: file, score: 0.48)
        }
        if ["setting", "preference", "option"].contains(where: lower.contains),
           let settings = elements.first(where: {
               let label = $0.bestLabel.lowercased()
               return label.contains("setting") || label.contains("preference")
           }) {
            return .init(element: settings, score: 0.5)
        }
        return nil
    }
}
