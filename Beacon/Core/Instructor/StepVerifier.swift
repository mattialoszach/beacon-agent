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
        if before.activeApplication.bundleIdentifier != after.activeApplication.bundleIdentifier {
            return StepVerification(
                succeeded: false,
                explanation: "The active application changed before Beacon could confirm the expected result."
            )
        }
        guard let expected else {
            return .init(succeeded: true, explanation: "The interface changed.")
        }
        let beforeLabels = Set(before.elements.map { $0.bestLabel.lowercased() })
        let afterLabels = Set(after.elements.map { $0.bestLabel.lowercased() })
        let beforeFocused = before.elements.first(where: \.focused)?.bestLabel
        let afterFocused = after.elements.first(where: \.focused)?.bestLabel
        let windowChanged = before.activeWindow?.title != after.activeWindow?.title
        let hierarchyChanged = beforeLabels != afterLabels

        let success: Bool
        switch expected.type {
        case .windowAppears:
            success = windowChanged || afterLabels.subtracting(beforeLabels).count >= 2
        case .windowDisappears:
            success = windowChanged || beforeLabels.subtracting(afterLabels).count >= 2
        case .focusedElementChanges:
            success = beforeFocused != afterFocused
        case .elementAppears:
            success = !afterLabels.subtracting(beforeLabels).isEmpty
        case .visualChange:
            success = windowChanged || hierarchyChanged || beforeFocused != afterFocused
                || (visualDifference ?? 0) >= FrameDifferenceDetector().meaningfulThreshold
        }
        return StepVerification(
            succeeded: success,
            explanation: success
                ? "Observed the expected interface change: \(expected.description)"
                : "The interface changed, but not in the expected way: \(expected.description)"
        )
    }
}
