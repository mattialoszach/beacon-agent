import Foundation

struct StepVerification: Equatable, Sendable {
    let succeeded: Bool
    let explanation: String
}

struct StepVerifier: Sendable {
    func verify(
        expected: ExpectedOutcome?,
        before: ScreenScene,
        after: ScreenScene,
        visualDifference: Double? = nil
    ) -> StepVerification {
        guard SceneIdentity.sameDisplays(before, after) else {
            return .init(succeeded: false, explanation: "The display configuration changed.")
        }
        let applicationChanged = !SceneIdentity.sameApplication(before, after)
        if applicationChanged,
           expected?.type != .windowAppears || expected?.applicationScope != .mayChange
            || expected?.destinationBundleIdentifier != after.activeApplication.bundleIdentifier {
            return .init(succeeded: false, explanation: "The active application changed before the expected result was confirmed.")
        }
        guard let expected, expected.canVerifyAutomatically else {
            return .init(succeeded: false, explanation: "This result needs confirmation from the user.")
        }
        let success: Bool
        if expected.type == .windowAppears {
            success = appearedWindow(matches: expected, before: before, after: after, applicationChanged: applicationChanged)
        } else {
            guard SceneIdentity.sameWindow(before.activeWindow, after.activeWindow),
                  let selector = expected.element else {
                return .init(succeeded: false, explanation: "The expected control is not in the original window.")
            }
            let old = verificationElements(
                in: before,
                windowID: before.activeWindow?.id,
                selector: selector
            )
            let new = verificationElements(
                in: after,
                windowID: after.activeWindow?.id,
                selector: selector
            )
            let matching = new.filter { selector.matches($0) && $0.enabled }
            // Ambiguous selectors must never choose an arbitrary matching control.
            guard matching.count == 1, let target = matching.first else {
                return .init(succeeded: false, explanation: "The expected control was absent or ambiguous.")
            }
            switch expected.type {
            case .elementAppears:
                success = !old.contains { selector.matches($0) }
            case .focusedElementChanges:
                success = target.focused && !old.contains { selector.matches($0) && $0.focused }
            case .visualChange:
                let previous = old.filter { $0.id == target.id && selector.matches($0, includingValue: false) }
                success = previous.count == 1 && previous.first?.value != target.value
            case .windowAppears, .windowDisappears:
                success = false
            }
        }
        return .init(succeeded: success, explanation: success
                     ? "Confirmed: \(expected.description)"
                     : "The expected result has not been confirmed: \(expected.description)")
    }

    /// Whether a failed raw-Accessibility verification has enough matching state to
    /// justify one local OCR refresh. Labels are deliberately ignored here; role, value,
    /// focus, stable identity, and the expected transition must still agree first.
    func mayBenefitFromLocalVisualContext(
        expected: ExpectedOutcome?,
        before: ScreenScene,
        after: ScreenScene
    ) -> Bool {
        guard let expected,
              expected.canVerifyAutomatically,
              let selector = expected.element,
              !selector.labels.isEmpty,
              after.visualElements.isEmpty else { return false }

        let old = SceneIdentity.elements(in: before, windowID: before.activeWindow?.id)
        let new = SceneIdentity.elements(in: after, windowID: after.activeWindow?.id)
        guard new.filter({ selector.matches($0) && $0.enabled }).count != 1 else {
            return false
        }
        guard selector.id != nil || selector.role != nil || selector.value != nil else {
            return false
        }
        let candidates = new.filter { element in
            guard element.enabled else { return false }
            if let id = selector.id, id != element.id { return false }
            if let role = selector.role, role != element.role { return false }
            if let value = selector.value,
               ExpectedElement.normalized(value)
                != ExpectedElement.normalized(element.value ?? "") { return false }
            return true
        }

        switch expected.type {
        case .elementAppears:
            return candidates.contains { candidate in
                !old.contains { $0.id == candidate.id }
            }
        case .focusedElementChanges:
            return candidates.contains { candidate in
                candidate.focused
                    && old.contains { $0.id == candidate.id && !$0.focused }
            }
        case .visualChange:
            return candidates.contains { candidate in
                old.contains { $0.id == candidate.id && $0.value != candidate.value }
            }
        case .windowAppears:
            let oldWindowIDs = Set(SceneIdentity.visibleWindows(in: before).compactMap(\.id))
            return candidates.contains { candidate in
                candidate.windowID.map { !oldWindowIDs.contains($0) } == true
            }
        case .windowDisappears:
            return false
        }
    }

    private func appearedWindow(
        matches expected: ExpectedOutcome, before: ScreenScene, after: ScreenScene, applicationChanged: Bool
    ) -> Bool {
        let oldIDs = Set(SceneIdentity.visibleWindows(in: before).compactMap(\.id))
        let candidates = SceneIdentity.visibleWindows(in: after).filter { window in
            guard let id = window.id, !id.isEmpty,
                  applicationChanged || !oldIDs.contains(id) else { return false }
            guard id == after.activeWindow?.id || window.parentWindowID == before.activeWindow?.id else { return false }
            if let title = expected.windowTitle,
               ExpectedElement.normalized(window.title ?? "") != ExpectedElement.normalized(title) { return false }
            if let selector = expected.element {
                return verificationElements(in: after, windowID: id, selector: selector)
                    .filter { selector.matches($0) && $0.enabled }.count == 1
            }
            return expected.windowTitle?.isEmpty == false
        }
        return candidates.count == 1
    }

    /// Set-of-Marks already owns the deterministic OCR-to-AX fusion rule used for
    /// grounding. Reusing it here keeps verification on the same stable element IDs and
    /// avoids treating OCR rectangles as independent controls.
    private func verificationElements(
        in scene: ScreenScene,
        windowID: String?,
        selector: ExpectedElement
    ) -> [UIElementDescriptor] {
        let query = selector.labels.joined(separator: " ")
        let marks = SetOfMarksBuilder().build(
            scene: scene,
            query: query.isEmpty ? nil : query
        )
        let fusedLabels: [String: String] = Dictionary(
            uniqueKeysWithValues: marks.compactMap { mark in
                guard let id = mark.elementID,
                      mark.visualElementID != nil else { return nil }
                return (id, mark.label)
            }
        )
        return SceneIdentity.elements(in: scene, windowID: windowID).map { element in
            guard !element.hasExplicitLabel,
                  let label = fusedLabels[element.id] else { return element }
            return UIElementDescriptor(
                id: element.id,
                role: element.role,
                subrole: element.subrole,
                label: label,
                title: element.title,
                value: element.value,
                enabled: element.enabled,
                focused: element.focused,
                bounds: element.bounds,
                windowID: element.windowID,
                selected: element.selected
            )
        }
    }
}
