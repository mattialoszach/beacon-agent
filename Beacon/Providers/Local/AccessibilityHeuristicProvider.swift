import Foundation

struct AccessibilityHeuristicProvider: InstructorModel {
    let id = "On-device accessibility matcher"
    let capabilities: ModelCapabilities = [.text, .structuredOutput, .local]

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        if request.mode == .ask {
            return InstructorResponse(
                message: explanation(for: request),
                action: nil,
                expectedOutcome: nil
            )
        }

        if let planned = ApplicationGuidePlanner().response(for: request) {
            return planned
        }

        let completedIDs = Set(request.guideContext?.completedSteps.compactMap(\.targetElementID) ?? [])
        let completedLabels = Set(request.guideContext?.completedSteps.compactMap { $0.targetLabel?.lowercased() } ?? [])
        let availableElements = request.scene.elements.filter {
            !completedIDs.contains($0.id) && !completedLabels.contains($0.bestLabel.lowercased())
        }
        guard let match = SemanticElementMatcher.bestMatch(for: request.question, in: availableElements)
            ?? navigationFallback(for: request.question, in: availableElements) else {
            let availableMarks = request.setOfMarks.filter {
                !completedIDs.contains($0.elementID ?? "") && !completedLabels.contains($0.label.lowercased())
            }
            if let mark = SetOfMarksMatcher.bestMatch(for: request.question, in: availableMarks) {
                return InstructorResponse(
                    message: "Select \(mark.mark.label).",
                    action: SuggestedAction(
                        type: .pointToElement,
                        targetElementId: nil,
                        targetBounds: nil,
                        targetMark: mark.mark.id,
                        overlay: mark.mark.source == .accessibility ? .spotlight : .rectangle
                    ),
                    expectedOutcome: ExpectedOutcome(
                        type: .visualChange,
                        description: "The visible interface should change after selecting \(mark.mark.label)."
                    )
                )
            }
            let availableVisuals = request.scene.visualElements.filter {
                !completedLabels.contains($0.bestLabel.lowercased())
            }
            if let visual = VisualElementMatcher.bestMatch(for: request.question, in: availableVisuals) {
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
                    ? "I don't see another matching control, so I can't confirm that the task is finished. Reveal the next control or ask a more specific question."
                    : "I couldn't confidently match that request to an accessible or visible control. Try naming the control or action more specifically.",
                action: nil,
                expectedOutcome: nil,
                taskComplete: false
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
        // Whole words only: substring checks made "reopen" and "blueprint" point at the
        // File menu, and the File branch shadowed every other intent.
        let words = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let settingsWords: Set<String> = [
            "setting", "settings", "preference", "preferences", "option", "options"
        ]
        let wantsSettings = !words.isDisjoint(with: settingsWords)
        if wantsSettings,
           let settings = elements.first(where: {
               let label = $0.bestLabel.lowercased()
               return $0.enabled && $0.bounds?.isValid == true
                   && (label.contains("setting") || label.contains("preference"))
           }) {
            return .init(element: settings, score: 0.5)
        }
        let fileWords: Set<String> = ["export", "save", "print", "open", "document", "pdf"]
        if !wantsSettings, !words.isDisjoint(with: fileWords),
           let file = elements.first(where: {
               $0.enabled && $0.bounds?.isValid == true
                   && ["file", "document"].contains($0.bestLabel.lowercased())
           }) {
            return .init(element: file, score: 0.48)
        }
        return nil
    }
}
