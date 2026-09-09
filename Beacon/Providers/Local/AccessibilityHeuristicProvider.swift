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
            // Stable identity prevents an actual repeat. Reusing a visible label on a
            // newly opened page is common (for example, Profile picture in an account
            // menu and again in Personal info) and must not hide the next real control.
            !completedIDs.contains($0.id)
        }
        guard let match = SemanticElementMatcher.bestMatch(for: request.question, in: availableElements)
            ?? navigationFallback(for: request.question, in: availableElements) else {
            let availableMarks = request.setOfMarks.filter {
                if let elementID = $0.elementID { return !completedIDs.contains(elementID) }
                return !completedLabels.contains($0.label.lowercased())
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
        let profileWords: Set<String> = [
            "account", "avatar", "photo", "picture", "profile"
        ]
        let appearanceWords: Set<String> = [
            "appearance", "color", "colour", "dark", "light", "theme", "themes"
        ]
        if !words.isDisjoint(with: profileWords),
           let profileTarget = profileNavigationTarget(in: elements) {
            return profileTarget
        }
        if !words.isDisjoint(with: appearanceWords),
           let appearanceTarget = appearanceNavigationTarget(in: elements) {
            return appearanceTarget
        }
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

    private func appearanceNavigationTarget(
        in elements: [UIElementDescriptor]
    ) -> SemanticElementMatcher.Match? {
        let ranked = elements.compactMap { element -> SemanticElementMatcher.Match? in
            guard element.enabled, element.bounds?.isValid == true else { return nil }
            let label = element.bestLabel.lowercased()
                .replacingOccurrences(of: "…", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let score: Double
            if label.contains("color theme") || label.contains("colour theme") {
                score = 0.88
            } else if ["theme", "themes", "appearance"].contains(label) {
                score = 0.8
            } else if label.contains("theme") {
                score = 0.76
            } else if label.contains("setting") || label.contains("preference") {
                score = 0.62
            } else if label == "code" {
                // Visual Studio Code's application menu is the first macOS step toward
                // Settings → Themes. Prefer it only when no later theme control exists.
                score = 0.5
            } else {
                return nil
            }
            return .init(element: element, score: score)
        }
        return ranked.sorted {
            $0.score == $1.score ? $0.element.id < $1.element.id : $0.score > $1.score
        }.first
    }

    private func profileNavigationTarget(
        in elements: [UIElementDescriptor]
    ) -> SemanticElementMatcher.Match? {
        let ranked = elements.compactMap { element -> SemanticElementMatcher.Match? in
            guard element.enabled, element.bounds?.isValid == true else { return nil }
            let label = element.bestLabel.lowercased()
            let score: Double
            if label.contains("change profile") || label.contains("edit profile")
                || label.contains("profile picture") || label.contains("profile photo") {
                score = 0.78
            } else if label.contains("personal info") || label.contains("personal information") {
                score = 0.72
            } else if label.contains("manage your google account") || label.contains("manage account") {
                score = 0.68
            } else if label.contains("account settings") || label == "account" {
                score = 0.6
            } else {
                return nil
            }
            return .init(element: element, score: score)
        }
        return ranked.sorted {
            $0.score == $1.score ? $0.element.id < $1.element.id : $0.score > $1.score
        }.first
    }
}
