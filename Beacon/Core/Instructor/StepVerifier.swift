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
            let old = SceneIdentity.elements(in: before, windowID: before.activeWindow?.id)
            let new = SceneIdentity.elements(in: after, windowID: after.activeWindow?.id)
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
                return after.elements.filter { $0.windowID == id && selector.matches($0) && $0.enabled }.count == 1
            }
            return expected.windowTitle?.isEmpty == false
        }
        return candidates.count == 1
    }
}
