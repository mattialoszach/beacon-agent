import Foundation

struct ModelSceneContext: Equatable, Sendable {
    let text: String
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
        self.maximumElements = maximumElements
        self.maximumCharacters = maximumCharacters
    }

    func build(for request: InstructorRequest) -> ModelSceneContext {
        let queryTokens = tokens(request.question)
        let windowBounds = request.scene.activeWindow?.bounds
        let marksByElementID = Dictionary(uniqueKeysWithValues: request.setOfMarks.compactMap { mark in
            mark.elementID.map { ($0, mark.id) }
        })
        let marksByVisualElementID = Dictionary(uniqueKeysWithValues: request.setOfMarks.compactMap { mark in
            mark.visualElementID.map { ($0, mark.id) }
        })
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
        var characterCount = 0
        for candidate in ranked.prefix(maximumElements) {
            let markID = marksByElementID[candidate.element.id]
            let line = promptLine(for: candidate.element, markID: markID)
            guard characterCount + line.count + 1 <= maximumCharacters else { break }
            lines.append(line)
            ids.insert(candidate.element.id)
            if let markID { markIDs.insert(markID) }
            characterCount += line.count + 1
        }

        let selectedVisualElements = request.scene.visualElements
            .sorted { $0.confidence > $1.confidence }
            .prefix(max(0, min(20, maximumElements - lines.count)))
        var visualIDs = Set<String>()
        for visual in selectedVisualElements {
            let bounds = format(visual.bounds)
            let markID = marksByVisualElementID[visual.id]
            let mark = markID.map { " mark=\($0)" } ?? ""
            let line = "[\(visual.id)\(mark)] visual=\(visual.kind.rawValue) \"\(sanitized(visual.bestLabel, limit: 100))\" confidence=\(Int(visual.confidence * 100))% bounds=\(bounds)"
            guard characterCount + line.count + 1 <= maximumCharacters else { continue }
            lines.append(line)
            visualIDs.insert(visual.id)
            if let markID { markIDs.insert(markID) }
            characterCount += line.count + 1
        }

        let omitted = max(0, request.scene.elements.count - ids.count)
        let completed = request.guideContext?.completedSteps.map {
            "Step \($0.number): \($0.instruction) [\($0.targetLabel ?? $0.targetElementID ?? "no target")]"
        }.joined(separator: "\n")
        let guide = request.guideContext.map {
            "Current guide step: \($0.stepNumber) of at most \($0.maximumSteps)\nCompleted steps:\n\(completed?.isEmpty == false ? completed! : "None")"
        } ?? ""
        let header = """
        Application: \(sanitized(request.scene.activeApplication.name, limit: 100))
        Window: \(sanitized(request.scene.activeWindow?.title ?? "Unknown", limit: 140))
        Mode: \(request.mode.rawValue)
        \(guide)
        Visible controls (ranked; \(omitted) lower-priority controls omitted).
        Prefer stable element IDs. A mark number refers to the same numbered region in the local visual preview:
        """
        return ModelSceneContext(
            text: header + "\n" + lines.joined(separator: "\n"),
            includedElementIDs: ids,
            includedVisualElementIDs: visualIDs,
            includedMarkIDs: markIDs,
            includedElementCount: ids.count,
            omittedElementCount: omitted
        )
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
        return "[\(element.id)\(mark)] \(role) \"\(label)\"\(flags.isEmpty ? "" : " (\(flags))")"
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
