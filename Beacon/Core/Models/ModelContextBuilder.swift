import Foundation

struct ModelSceneContext: Equatable, Sendable {
    let text: String
    let userPrompt: String
    let includedElementIDs: Set<String>
    let includedVisualElementIDs: Set<String>
    let includedMarkIDs: Set<Int>
    let includedElementCount: Int
    let omittedElementCount: Int
}

/// Converts a potentially huge accessibility scene into a deterministic, bounded model prompt.
/// Grounding still resolves against the complete local scene.
struct ModelContextBuilder: Sendable {
    let maximumElements: Int
    let maximumCharacters: Int

    init(maximumElements: Int = 48, maximumCharacters: Int = 6_000) {
        self.maximumElements = max(0, maximumElements)
        self.maximumCharacters = max(0, maximumCharacters)
    }

    func build(for request: InstructorRequest) -> ModelSceneContext {
        let question = String(request.question.prefix(min(1_000, maximumCharacters / 4)))
        let questionLine = String("Question: \(question)\n".prefix(maximumCharacters))
        let contextBudget = maximumCharacters - questionLine.count
        let header = header(for: request, budget: contextBudget / 2)
        let queryTokens = tokens(question)
        let windowBounds = request.scene.activeWindow?.bounds
        let marksByElementID = Dictionary(request.setOfMarks.compactMap { mark in
            mark.elementID.map { ($0, mark) }
        }, uniquingKeysWith: { first, _ in first })
        let marksByVisualElementID = Dictionary(request.setOfMarks.compactMap { mark in
            mark.visualElementID.map { ($0, mark.id) }
        }, uniquingKeysWith: { first, _ in first })
        let rankedVisualCandidates = request.scene.visualElements
            .filter { $0.bounds.isValid && $0.confidence.isFinite && (0...1).contains($0.confidence) }
            .filter { !isRepresentedByAccessibilityMark($0, marks: request.setOfMarks) }
            .map {
                (
                    element: $0,
                    relevance: visualRelevance(for: $0, question: question)
                )
            }
            .sorted {
                if $0.relevance != $1.relevance { return $0.relevance > $1.relevance }
                if $0.element.confidence != $1.element.confidence {
                    return $0.element.confidence > $1.element.confidence
                }
                return $0.element.id < $1.element.id
            }
        let rankedVisuals = rankedVisualCandidates.map(\.element)
        // OCR is often the only label for SwiftUI-backed controls. Reserve part of the
        // total element budget before AX fills it, while keeping the visual share bounded.
        let relevantVisualCount = rankedVisualCandidates.prefix { $0.relevance > 0 }.count
        let reservedVisualCount = min(
            relevantVisualCount,
            min(Self.maximumReservedVisualElements, maximumElements / 4)
        )
        let ranked = request.scene.elements
            .filter { $0.enabled && $0.bounds?.isValid == true }
            .map { element in
                let mark = marksByElementID[element.id]
                return (
                    element: element,
                    mark: mark,
                    score: score(
                        element,
                        supplementalMark: mark,
                        question: question,
                        queryTokens: queryTokens,
                        windowBounds: windowBounds
                    )
                )
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.element.focused != $1.element.focused { return $0.element.focused }
                return $0.element.id < $1.element.id
            }

        var lines: [String] = []
        var ids = Set<String>()
        var visualIDs = Set<String>()
        var markIDs = Set<Int>()
        var characterCount = header.count

        // Add the reserved visual candidates first so long AX labels cannot consume the
        // character budget that made those slots useful in the first place.
        for visual in rankedVisuals.prefix(reservedVisualCount) {
            let line = visualPromptLine(
                for: visual,
                markID: marksByVisualElementID[visual.id]
            )
            guard characterCount + line.count + 1 <= contextBudget else { continue }
            lines.append(line)
            visualIDs.insert(visual.id)
            if let markID = marksByVisualElementID[visual.id] { markIDs.insert(markID) }
            characterCount += line.count + 1
        }

        let maximumAccessibilityCount = max(0, maximumElements - visualIDs.count)
        for candidate in ranked.prefix(maximumAccessibilityCount) {
            let line = promptLine(for: candidate.element, mark: candidate.mark)
            guard characterCount + line.count + 1 <= contextBudget else { continue }
            lines.append(line)
            ids.insert(candidate.element.id)
            if let markID = candidate.mark?.id { markIDs.insert(markID) }
            characterCount += line.count + 1
        }

        // If AX did not use every slot, retain the previous behavior of admitting more
        // visual context, still under a strict per-prompt visual cap.
        for visual in rankedVisuals where lines.count < maximumElements
            && visualIDs.count < Self.maximumVisualElements {
            guard !visualIDs.contains(visual.id) else { continue }
            let line = visualPromptLine(
                for: visual,
                markID: marksByVisualElementID[visual.id]
            )
            guard characterCount + line.count + 1 <= contextBudget else { continue }
            lines.append(line)
            visualIDs.insert(visual.id)
            if let markID = marksByVisualElementID[visual.id] { markIDs.insert(markID) }
            characterCount += line.count + 1
        }

        let omitted = max(0, request.scene.elements.count - ids.count)
        let text = header + lines.map { "\n" + $0 }.joined()
        return ModelSceneContext(
            text: text,
            userPrompt: questionLine + text,
            includedElementIDs: ids,
            includedVisualElementIDs: visualIDs,
            includedMarkIDs: markIDs,
            includedElementCount: ids.count,
            omittedElementCount: omitted
        )
    }

    private func header(for request: InstructorRequest, budget: Int) -> String {
        var header = """
        Application: \(sanitized(request.scene.activeApplication.name, limit: 100))
        Window: \(sanitized(request.scene.activeWindow?.title ?? "Unknown", limit: 140))
        Mode: \(request.mode.rawValue)
        """
        if let guide = request.guideContext {
            header += "\nGuide step: \(guide.stepNumber)/\(guide.maximumSteps). Completed steps:"
            let steps = guide.completedSteps.suffix(8)
            let lineBudget = max(0, (budget - header.count) / max(1, steps.count))
            for step in steps {
                let prefix = "\nStep \(step.number): "
                let fieldBudget = max(0, (lineBudget - prefix.count - 3) / 2)
                header += prefix + sanitized(step.instruction, limit: min(160, fieldBudget))
                    + " [" + sanitized(step.targetLabel ?? "no target", limit: min(80, fieldBudget)) + "]"
            }
        }
        if request.continuationRequested {
            header += "\nContinuation requested: Re-check the goal and provide another useful step if one remains. Otherwise complete again."
        }
        return String(header.prefix(budget))
    }

    private func score(
        _ element: UIElementDescriptor,
        supplementalMark: SetOfMark?,
        question: String,
        queryTokens: Set<String>,
        windowBounds: NormalizedRect?
    ) -> Int {
        let label = effectiveLabel(for: element, mark: supplementalMark)
        let candidate = [element.label, element.title, element.value, element.role, label]
            .compactMap { $0 }.joined(separator: " ")
        let candidateTokens = tokens(candidate)
        var result = queryTokens.intersection(candidateTokens).count * 100
        result += Int((SemanticElementMatcher.relevanceScore(
            query: question,
            candidate: candidate
        ) * 100).rounded())
        if element.focused { result += 80 }
        if label != "Unlabelled control" { result += 20 }
        if let role = element.role, Self.actionableRoles.contains(role) { result += 15 }
        if let windowBounds, let bounds = element.bounds, contains(windowBounds, bounds) { result += 10 }
        if element.role == "AXMenuBarItem" || element.role == "AXMenuItem" { result += 8 }
        return result
    }

    private func promptLine(for element: UIElementDescriptor, mark: SetOfMark?) -> String {
        let role = sanitized(element.role ?? "UIElement", limit: 40)
        let label = sanitized(effectiveLabel(for: element, mark: mark), limit: 120)
        let flags = [
            element.focused ? "focused" : nil,
            element.selected == true ? "selected" : nil
        ].compactMap { $0 }.joined(separator: ",")
        let markText = mark.map { " mark=\($0.id)" } ?? ""
        let value = ["AXCheckBox", "AXRadioButton", "AXPopUpButton"].contains(element.role ?? "")
            ? element.value.map { " value=\"\(sanitized($0, limit: 80))\"" } ?? "" : ""
        return "[\(element.id)\(markText)] \(role) \"\(label)\"\(value)\(flags.isEmpty ? "" : " (\(flags))")"
    }

    private func visualPromptLine(for visual: VisualElementDescriptor, markID: Int?) -> String {
        let mark = markID.map { " mark=\($0)" } ?? ""
        return "[\(visual.id)\(mark)] visual=\(visual.kind.rawValue) \"\(sanitized(visual.bestLabel, limit: 100))\" confidence=\(Int(visual.confidence * 100))% bounds=\(format(visual.bounds))"
    }

    private func effectiveLabel(for element: UIElementDescriptor, mark: SetOfMark?) -> String {
        guard !element.hasExplicitLabel,
              let mark,
              mark.visualElementID != nil else { return element.bestLabel }
        return mark.label
    }

    private func visualRelevance(
        for visual: VisualElementDescriptor,
        question: String
    ) -> Double {
        let normalized = question.lowercased()
        var score = SemanticElementMatcher.relevanceScore(
            query: question,
            candidate: visual.bestLabel
        )
        if visual.kind == .circle,
           normalized.contains("circle") || normalized.contains("round") { score += 0.5 }
        if visual.kind == .rectangle,
           normalized.contains("rectangle") || normalized.contains("square")
            || normalized.contains("box") { score += 0.5 }
        if visual.kind == .icon,
           normalized.contains("icon") || normalized.contains("symbol") { score += 0.5 }
        if visual.kind == .canvasShape,
           normalized.contains("shape") || normalized.contains("object")
            || normalized.contains("drawing") { score += 0.5 }
        if normalized.contains("left"), visual.bounds.center.x <= 0.42 { score += 0.1 }
        if normalized.contains("right"), visual.bounds.center.x >= 0.58 { score += 0.1 }
        if normalized.contains("top"), visual.bounds.center.y <= 0.42 { score += 0.1 }
        if normalized.contains("bottom"), visual.bounds.center.y >= 0.58 { score += 0.1 }
        return score
    }

    private func isRepresentedByAccessibilityMark(
        _ visual: VisualElementDescriptor,
        marks: [SetOfMark]
    ) -> Bool {
        marks.contains { mark in
            mark.elementID != nil
                && ExpectedElement.normalized(mark.label)
                    == ExpectedElement.normalized(visual.bestLabel)
                && overlapRatio(mark.bounds, visual.bounds) > 0.58
        }
    }

    private func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .subtracting(Self.stopWords)
    }

    private func sanitized(_ value: String, limit: Int) -> String {
        if SensitiveTextDetector().kind(of: value) != nil { return "[redacted sensitive text]" }
        return String(value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .prefix(limit))
    }

    private func format(_ rect: NormalizedRect) -> String {
        String(format: "%.4f,%.4f,%.4f,%.4f", rect.x, rect.y, rect.width, rect.height)
    }

    private func contains(_ outer: NormalizedRect, _ inner: NormalizedRect) -> Bool {
        inner.center.x >= outer.x && inner.center.x <= outer.x + outer.width
            && inner.center.y >= outer.y && inner.center.y <= outer.y + outer.height
    }

    private func overlapRatio(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let width = max(
            0,
            min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x)
        )
        let height = max(
            0,
            min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y)
        )
        return width * height
            / max(0.000_000_1, min(lhs.width * lhs.height, rhs.width * rhs.height))
    }

    private static let actionableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXComboBox", "AXLink", "AXMenuBarItem", "AXMenuItem",
        "AXPopUpButton", "AXRadioButton", "AXRow", "AXSlider", "AXTabGroup", "AXTextField"
    ]

    private static let maximumReservedVisualElements = 12
    private static let maximumVisualElements = 20

    private static let stopWords: Set<String> = [
        "a", "about", "an", "can", "do", "does", "how", "i", "is", "me", "my",
        "of", "on", "please", "the", "this", "to", "where", "with"
    ]
}
