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
            mark.elementID.map { ($0, mark.id) }
        }, uniquingKeysWith: { first, _ in first })
        let marksByVisualElementID = Dictionary(request.setOfMarks.compactMap { mark in
            mark.visualElementID.map { ($0, mark.id) }
        }, uniquingKeysWith: { first, _ in first })
        let ranked = request.scene.elements
            .filter { $0.enabled && $0.bounds?.isValid == true }
            .map { element in
                (element: element, score: score(element, queryTokens: queryTokens, windowBounds: windowBounds))
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.element.focused != $1.element.focused { return $0.element.focused }
                return $0.element.id < $1.element.id
            }

        var lines: [String] = []
        var ids = Set<String>()
        var markIDs = Set<Int>()
        var characterCount = header.count
        for candidate in ranked.prefix(maximumElements) {
            let markID = marksByElementID[candidate.element.id]
            let line = promptLine(for: candidate.element, markID: markID)
            guard characterCount + line.count + 1 <= contextBudget else { continue }
            lines.append(line)
            ids.insert(candidate.element.id)
            if let markID { markIDs.insert(markID) }
            characterCount += line.count + 1
        }

        let selectedVisualElements = request.scene.visualElements
            .filter { $0.bounds.isValid && $0.confidence.isFinite && (0...1).contains($0.confidence) }
            .sorted { $0.confidence == $1.confidence ? $0.id < $1.id : $0.confidence > $1.confidence }
            .prefix(max(0, min(20, maximumElements - lines.count)))
        var visualIDs = Set<String>()
        for visual in selectedVisualElements {
            let bounds = format(visual.bounds)
            let markID = marksByVisualElementID[visual.id]
            let mark = markID.map { " mark=\($0)" } ?? ""
            let line = "[\(visual.id)\(mark)] visual=\(visual.kind.rawValue) \"\(sanitized(visual.bestLabel, limit: 100))\" confidence=\(Int(visual.confidence * 100))% bounds=\(bounds)"
            guard characterCount + line.count + 1 <= contextBudget else { continue }
            lines.append(line)
            visualIDs.insert(visual.id)
            if let markID { markIDs.insert(markID) }
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
        return String(header.prefix(budget))
    }

    private func score(
        _ element: UIElementDescriptor,
        queryTokens: Set<String>,
        windowBounds: NormalizedRect?
    ) -> Int {
        let candidateTokens = tokens([element.label, element.title, element.value, element.role]
            .compactMap { $0 }.joined(separator: " "))
        var result = queryTokens.intersection(candidateTokens).count * 100
        if element.focused { result += 80 }
        if element.bestLabel != "Unlabelled control" { result += 20 }
        if let role = element.role, Self.actionableRoles.contains(role) { result += 15 }
        if let windowBounds, let bounds = element.bounds, contains(windowBounds, bounds) { result += 10 }
        if element.role == "AXMenuBarItem" || element.role == "AXMenuItem" { result += 8 }
        return result
    }

    private func promptLine(for element: UIElementDescriptor, markID: Int?) -> String {
        let role = sanitized(element.role ?? "UIElement", limit: 40)
        let label = sanitized(element.bestLabel, limit: 120)
        let flags = [element.focused ? "focused" : nil].compactMap { $0 }.joined(separator: ",")
        let mark = markID.map { " mark=\($0)" } ?? ""
        let value = ["AXCheckBox", "AXRadioButton", "AXPopUpButton"].contains(element.role ?? "")
            ? element.value.map { " value=\"\(sanitized($0, limit: 80))\"" } ?? "" : ""
        return "[\(element.id)\(mark)] \(role) \"\(label)\"\(value)\(flags.isEmpty ? "" : " (\(flags))")"
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

    private static let actionableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXComboBox", "AXLink", "AXMenuBarItem", "AXMenuItem",
        "AXPopUpButton", "AXRadioButton", "AXSlider", "AXTabGroup", "AXTextField"
    ]

    private static let stopWords: Set<String> = [
        "a", "about", "an", "can", "do", "does", "how", "i", "is", "me", "my",
        "of", "on", "please", "the", "this", "to", "where", "with"
    ]
}
